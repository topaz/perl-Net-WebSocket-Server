package Net::WebSocket::Server;

use 5.006;
use strict;
use warnings FATAL => 'all';

use Carp;
use IO::Socket::INET;
use IO::Select;
use Net::WebSocket::Server::Connection;
use Time::HiRes qw(time);

our $VERSION = '0.001003';
$VERSION = eval $VERSION;

sub new {
  my $class = shift;

  my %params = @_;

  my $self = {
    listen      => 80,
    silence_max => 20,
    on_connect  => sub{},
  };

  while (my ($key, $value) = each %params ) {
    croak "Invalid $class parameter '$key'" unless exists $self->{$key};
    croak "$class parameter '$key' expects a coderef" if ref $self->{$key} eq 'CODE' && ref $value ne 'CODE';
    $self->{$key} = $value;
  }

  # send a ping every silence_max by checking whether data was received in the last silence_max/2
  $self->{silence_checkinterval} = $self->{silence_max} / 2;

  bless $self, $class;
}

sub on {
  my $self = shift;
  my %params = @_;

  while (my ($key, $value) = each %params ) {
    croak "Invalid event '$key'" unless exists $self->{"on_$key"};
    croak "Expected a coderef for event '$key'" unless ref $value eq 'CODE';
    $self->{"on_$key"} = $value;
  }
}

sub start {
  my $self = shift;

  # if we merely got a port, set up a reasonable default tcp server
  $self->{listen} = IO::Socket::INET->new(
    Listen    => 5,
    LocalPort => $self->{listen},
    Proto     => 'tcp',
    ReuseAddr => 1,
  ) or croak "failed to listen on port $self->{listen}: $!" unless ref $self->{listen};

  $self->{select} = IO::Select->new($self->{listen});
  $self->{conns} = {};
  $self->{silence_nextcheck} = $self->{silence_max} ? (time + $self->{silence_checkinterval}) : 0;

  while ($self->{select}->count) {
    my $silence_checktimeout = $self->{silence_max} ? ($self->{silence_nextcheck} - time) : undef;
    my @ready = $self->{select}->can_read($silence_checktimeout);
    foreach my $fh (@ready) {
      if ($fh == $self->{listen}) {
        my $sock = $self->{listen}->accept;
        my $conn = new Net::WebSocket::Server::Connection(socket => $sock, server => $self);
        $self->{conns}{$sock} = {conn=>$conn, lastrecv=>time};
        $self->{select}->add($sock);
        $self->{on_connect}($self, $conn);
      } else {
        my $connmeta = $self->{conns}{$fh};
        $connmeta->{lastrecv} = time;
        $connmeta->{conn}->recv();
      }
    }

    if ($self->{silence_max}) {
      my $now = time;
      if ($self->{silence_nextcheck} < $now) {
        my $lastcheck = $self->{silence_nextcheck} - $self->{silence_checkinterval};
        $_->{conn}->send('ping') for grep { $_->{lastrecv} < $lastcheck } values %{$self->{conns}};

        $self->{silence_nextcheck} = $now + $self->{silence_checkinterval};
      }
    }
  }
}

sub connections { map {$_->{conn}} values %{$_[0]{conns}} }

sub shutdown {
  my ($self) = @_;
  $self->{select}->remove($self->{listen});
  $self->{listen}->close();
  $_->disconnect(1001) for $self->connections;
}

sub disconnect {
  my ($self, $fh) = @_;
  $self->{select}->remove($fh);
  $fh->close();
  delete $self->{conns}{$fh};
}

1; # End of Net::WebSocket::Server

__END__

=head1 NAME

Net::WebSocket::Server -  A straightforward Perl WebSocket server with minimal dependencies. 

=head1 SYNOPSIS

Simple echo server for C<utf8> messages.

    use Net::WebSocket::Server;

    Net::WebSocket::Server->new(
        listen => 8080,
        on_connect => sub {
            my ($serv, $conn) = @_;
            $conn->on(
                utf8 => sub {
                    my ($conn, $msg) = @_;
                    $conn->send_utf8($msg);
                },
            );
        },
    )->start;

Broadcast-echo server for C<utf8> and C<binary> messages.

    use Net::WebSocket::Server;

    my $origin = 'http://example.com';

    Net::WebSocket::Server->new(
        listen => 8080,
        on_connect => sub {
            my ($serv, $conn) = @_;
            $conn->on(
                handshake => sub {
                    my ($conn, $handshake) = @_;
                    $conn->disconnect() unless $handshake->req->origin eq $origin;
                },
                utf8 => sub {
                    my ($conn, $msg) = @_;
                    $_->send_utf8($msg) for $conn->server->connections;
                },
                binary => sub {
                    my ($conn, $msg) = @_;
                    $_->send_binary($msg) for $conn->server->connections;
                },
            );
        },
    )->start;

=head1 DESCRIPTION

This module implements the details of a WebSocket server and invokes the
provided callbacks whenever something interesting happens.  Individual
connections to the server are represented as
L<Net::WebSocket::Server::Connection|Net::WebSocket::Server::Connection>
objects.

=head1 CONSTRUCTION

=over

=item C<< Net::WebSocket::Server->new(I<%opts>) >>

    Net::WebSocket::Server->new(
        listen => 8080,
        on_connect => sub { ... },
    ),

Creates a new C<Net::WebSocket::Server> object with the given configuration.
Takes the following parameters:

=over

=item C<listen>

If not a reference, the TCP port on which to listen.  If a reference, a
preconfigured L<IO::Socket::INET|IO::Socket::INET> TCP server to use.  Default C<80>.

=item C<silence_max>

The maximum amount of time in seconds to allow silence on each connection's
socket.  Every C<silence_max/2> seconds, each connection is checked for
whether data was received since the last check; if not, a WebSocket ping
message is sent.  Set to C<0> to disable.  Default C<20>.

=item C<on_C<$event>>

The callback to invoke when the given C<$event> occurs, such as C<on_connect>.
See L</EVENTS>.

=back

=back

=head1 METHODS

=over

=item C<on(I<%events>)>

    $server->on(
        connect => sub { ... },
    ),

Takes a list of C<< $event => $callback >> pairs; C<$event> names should not
include an C<on_> prefix.  Typically, events are configured once via the
L<constructor|/CONSTRUCTION> rather than later via this method.  See L</EVENTS>.

=item C<start()>

Starts the WebSocket server; registered callbacks will be invoked as
interesting things happen.  Does not return until L<shutdown()/shutdown> is
called.

=item C<connections()>

Returns a list of the current
L<Net::WebSocket::Server::Connection|Net::WebSocket::Server::Connection>
objects.

=item C<disconnect(I<$socket>)>

Immediately disconnects the given C<$socket> without calling the corresponding
connection's callback or cleaning up the socket.  For that, see
L<Net::WebSocket::Server::Connection/disconnect>, which ultimately calls this
function anyway.

=item C<shutdown()>

Closes the listening socket and cleanly disconnects all clients, causing the
L<start()|/start> method to return.

=back

=head1 EVENTS

Attach a callback for an event by either passing C<on_$event> parameters to the
L<constructor|/CONSTRUCTION> or by passing C<$event> parameters to the
L<on()|/on> method.

=over

=item C<connect(I<$server>, I<$connection>)>

Invoked when a new connection is made.  Use this event to configure the
newly-constructed
L<Net::WebSocket::Server::Connection|Net::WebSocket::Server::Connection>
object.  Arguments passed to the callback are the server accepting the
connection and the new connection object itself.

=back

=head1 AUTHOR

Eric Wastl, C<< <topaz at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-net-websocket-server at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Net-WebSocket-Server>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Net::WebSocket::Server

You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Net-WebSocket-Server>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Net-WebSocket-Server>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Net-WebSocket-Server>

=item * Search CPAN

L<http://search.cpan.org/dist/Net-WebSocket-Server/>

=back

=head1 LICENSE AND COPYRIGHT

Copyright 2013 Eric Wastl.

This program is free software; you can redistribute it and/or modify it
under the terms of the the Artistic License (2.0). You may obtain a
copy of the full license at:

L<http://www.perlfoundation.org/artistic_license_2_0>

Any use, modification, and distribution of the Standard or Modified
Versions is governed by this Artistic License. By using, modifying or
distributing the Package, you accept this license. Do not use, modify,
or distribute the Package, if you do not accept this license.

If your Modified Version has been derived from a Modified Version made
by someone other than you, you are nevertheless required to ensure that
your Modified Version complies with the requirements of this license.

This license does not grant you the right to use any trademark, service
mark, tradename, or logo of the Copyright Holder.

This license includes the non-exclusive, worldwide, free-of-charge
patent license to make, have made, use, offer to sell, sell, import and
otherwise transfer the Package with respect to any patent claims
licensable by the Copyright Holder that are necessarily infringed by the
Package. If you institute patent litigation (including a cross-claim or
counterclaim) against any party alleging that the Package constitutes
direct or contributory patent infringement, then this Artistic License
to you shall terminate on the date that such litigation is filed.

Disclaimer of Warranty: THE PACKAGE IS PROVIDED BY THE COPYRIGHT HOLDER
AND CONTRIBUTORS "AS IS' AND WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES.
THE IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE, OR NON-INFRINGEMENT ARE DISCLAIMED TO THE EXTENT PERMITTED BY
YOUR LOCAL LAW. UNLESS REQUIRED BY LAW, NO COPYRIGHT HOLDER OR
CONTRIBUTOR WILL BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, OR
CONSEQUENTIAL DAMAGES ARISING IN ANY WAY OUT OF THE USE OF THE PACKAGE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
