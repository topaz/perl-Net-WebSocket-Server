#!perl -T
use 5.006;
use strict;
use warnings FATAL => 'all';
use Test::More;

use Protocol::WebSocket::Handshake::Client;
use Protocol::WebSocket::Frame;
use IO::Socket::INET;

my $child;
sub cleanup { kill 9 => $child if $child && $child > 0 }
$SIG{ALRM} = sub { cleanup; die "test timed out\n"; };
alarm(10);

my $listen = IO::Socket::INET->new(Listen => 2, Proto => 'tcp', Timeout => 5) or die "$!";

unless ($child = fork) {
  delete $SIG{ALRM};
  require Net::WebSocket::Server;

  Net::WebSocket::Server->new(
    listen => $listen,
    on_connect => sub {
      my ($serv, $conn) = @_;
      $conn->on(
        handshake => sub {
          my ($conn, $hs) = @_;
          die "bad handshake origin: " . $hs->req->origin unless $hs->req->origin eq 'http://localhost';
          die "bad subprotocol: " . $hs->req->subprotocol unless $hs->req->subprotocol eq 'test subprotocol';
        },
        ready => sub {
          my ($conn) = @_;
          $conn->send_binary("ready");
        },
        utf8 => sub {
          my ($conn, $msg) = @_;
          $conn->send_utf8("utf8(".length($msg).") = $msg");
        },
        binary => sub {
          my ($conn, $msg) = @_;
          $conn->send_binary("binary(".length($msg).") = $msg");
        },
        pong => sub {
          my ($conn, $msg) = @_;
          $conn->send_binary("pong(".length($msg).") = $msg");
        },
        disconnect => sub {
          my ($conn, $code, $reason) = @_;
          die "bad disconnect code" unless $code == 4242;
          die "bad disconnect reason" unless $reason eq 'test server shutdown cleanly';
          $serv->shutdown();
        },
      );
    },
  )->start;

  exit;
}

my $port = $listen->sockport;
my $sock = IO::Socket::INET->new(PeerPort => $port, Proto => 'tcp', PeerAddr => 'localhost')
        || IO::Socket::INET->new(PeerPort => $port, Proto => 'tcp', PeerAddr => '127.0.0.1')
        or die "$! (maybe your system does not have a localhost at all, 'localhost' or 127.0.0.1)";

my $hs = Protocol::WebSocket::Handshake::Client->new(url => 'ws://localhost/testserver');
$hs->req->subprotocol("test subprotocol");
print $sock $hs->to_string;

my $buf = "";
while(sysread($sock, $buf, 8192, length($buf))) {
  $hs->parse($buf);
  last if $hs->is_done;
}

ok(!$hs->error, "completed handshake with server without error");
is(length($buf), 0, "expected empty buffer after handshake");

my $parser = new Protocol::WebSocket::Frame();

ok(_recv($sock => $parser), "got message without disconnect");
my $bytes = $parser->next_bytes;
ok($parser->is_binary, "expected binary message");
is($bytes, "ready", "expected welcome 'ready' message");

foreach my $msg ("simple", "", ("a" x 32768), "unicode \u2603 snowman", "hiragana \u3072\u3089\u304c\u306a null \x00 ctrls \cA \cF \n \e del \x7f end") {
  print $sock Protocol::WebSocket::Frame->new(type=>'text', buffer=>$msg)->to_bytes;
  ok(_recv($sock => $parser), "got message without disconnect");
  my $bytes = $parser->next_bytes;
  ok($parser->is_text, "expected text message");
  is($bytes, "utf8(" . length($msg) . ") = $msg");
}

foreach my $msg ("simple", "", ("a" x 32768), "unicode \u2603 snowman", "hiragana \u3072\u3089\u304c\u306a null \x00 ctrls \cA \cF \n \e del \x7f end", join("", map{chr($_)} 0..255)) {
  print $sock Protocol::WebSocket::Frame->new(type=>'binary', buffer=>$msg)->to_bytes;
  ok(_recv($sock => $parser), "got message without disconnect");
  my $bytes = $parser->next_bytes;
  ok($parser->is_binary, "expected binary message");
  is($bytes, "binary(" . length($msg) . ") = $msg");
}

foreach my $msg ("simple", "", ("a" x 32768), "unicode \u2603 snowman", "hiragana \u3072\u3089\u304c\u306a null \x00 ctrls \cA \cF \n \e del \x7f end", join("", map{chr($_)} 0..255)) {
  print $sock Protocol::WebSocket::Frame->new(type=>'pong', buffer=>$msg)->to_bytes;
  ok(_recv($sock => $parser), "got message without disconnect");
  my $bytes = $parser->next_bytes;
  ok($parser->is_binary, "expected binary message");
  is($bytes, "pong(" . length($msg) . ") = $msg");
}

ok((kill 0 => $child), "child should still be alive");
print $sock Protocol::WebSocket::Frame->new(type=>'close', buffer=>pack("n",4242)."test server shutdown cleanly")->to_bytes;
waitpid $child, 0;
ok(!(kill 0 => $child), "child should have shut down cleanly");

done_testing();
cleanup();

sub _recv {
  my ($sock, $parser) = @_;

  my ($len, $data) = (0, "");
  if (!($len = sysread($sock, $data, 8192))) {
    return undef;
  }

  # read remaining data
  $len = sysread($sock, $data, 8192, length($data)) while $len >= 8192;

  $parser->append($data);
  return 1;
}
