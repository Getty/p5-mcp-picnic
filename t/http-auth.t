#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::File qw(curfile);
use Mojo::Server::Daemon;
use WWW::Picnic;

# Network-free tests for the client authentication of bin/mcp-picnic-http:
# the bearer token in front of /api/* and /mcp, and the rule that a server
# without a token only ever serves loopback clients. The WWW::Picnic methods
# the routes reach are replaced, so no login, HTTP request or 2FA SMS happens;
# @calls records every time the account would have been touched.

my @calls;

{
  package Fake::LoginResult;
  sub requires_2fa { 0 }

  package Fake::User;
  sub user_id          { 'u-1' }
  sub firstname        { 'Erika' }
  sub lastname         { 'Mustermann' }
  sub address          { { street => 'Heidestrasse 17' } }
  sub phone            { '+49 30 1234567' }
  sub total_deliveries { 3 }
}

{
  no warnings 'redefine';
  *WWW::Picnic::login    = sub { push @calls, 'login';    bless {}, 'Fake::LoginResult' };
  *WWW::Picnic::get_user = sub { push @calls, 'get_user'; bless {}, 'Fake::User' };
}

my $script = curfile->dirname->sibling('bin', 'mcp-picnic-http');
my $token  = 'correct-horse-battery-staple';

# Load the script as a fresh application under the given environment. The
# script is loaded more than once per process here, so its named subs are
# redefined; only that warning is silenced.
sub load_app {
  my (%env) = @_;
  local %ENV = (
    %ENV,
    PICNIC_USER => 'dummy@example.com',
    PICNIC_PASS => 'dummy-pass',
  );
  delete @ENV{qw(MCP_PICNIC_TOKEN MOJO_LISTEN MOJO_REVERSE_PROXY)};
  $ENV{$_} = $env{$_} for keys %env;
  local $SIG{__WARN__} = sub { warn @_ unless $_[0] =~ /redefined/ };
  my $t = Test::Mojo->new($script);
  $t->app->log->level('fatal');
  return wantarray ? ($t, $ENV{MOJO_LISTEN}) : $t;
}

sub bearer { return { Authorization => "Bearer $_[0]" } }

my %mcp_initialize = (
  jsonrpc => '2.0',
  id      => 1,
  method  => 'initialize',
  params  => {
    protocolVersion => '2025-06-18',
    capabilities    => {},
    clientInfo      => { name => 'http-auth.t', version => '1' },
  },
);

subtest 'with a token every account route demands it' => sub {
  my $t = load_app(MCP_PICNIC_TOKEN => $token);

  @calls = ();
  $t->get_ok('/api/user')
    ->status_is(401)
    ->header_is('WWW-Authenticate' => 'Bearer')
    ->json_is('/error' => 'Unauthorized')
    ->json_hasnt('/firstname');

  $t->get_ok('/api/user' => bearer('wrong-token'))->status_is(401);
  $t->get_ok('/api/user' => bearer(substr $token, 0, -1))->status_is(401, 'prefix of the token');
  $t->get_ok('/api/user' => bearer($token . 'x'))->status_is(401, 'token with a suffix');
  $t->get_ok('/api/user' => { Authorization => $token })->status_is(401, 'token without the Bearer scheme');
  $t->get_ok('/api/user' => { Authorization => "Basic $token" })->status_is(401, 'wrong scheme');
  $t->get_ok("/api/user?token=$token")->status_is(401, 'token in the query string');

  $t->get_ok('/api/auth/status')->status_is(401);
  $t->post_ok('/api/auth/login')->status_is(401);
  $t->get_ok('/api/cart')->status_is(401);
  $t->post_ok('/api/cart/clear')->status_is(401);
  $t->post_ok('/mcp' => json => \%mcp_initialize)->status_is(401);

  is_deeply \@calls, [], 'no rejected request reached the Picnic account';

  $t->get_ok('/api/user' => bearer($token))
    ->status_is(200)
    ->json_is('/firstname' => 'Erika');
  is_deeply \@calls, [qw(login get_user)], 'the request with the token is served';

  $t->get_ok('/api/auth/status' => bearer($token))->status_is(200)->json_is('/status' => 'authenticated');
  $t->post_ok('/mcp' => bearer($token) => json => \%mcp_initialize)
    ->status_is(200)
    ->json_is('/result/serverInfo/name' => 'Picnic');
};

subtest 'with a token the OpenAPI document tells clients to send it' => sub {
  my $t = load_app(MCP_PICNIC_TOKEN => $token);

  $t->get_ok('/openapi.json')
    ->status_is(200)
    ->json_is('/components/securitySchemes/bearerAuth' => { type => 'http', scheme => 'bearer' })
    ->json_is('/security' => [{ bearerAuth => [] }]);
  $t->get_ok('/')->status_is(200)->json_is('/name' => 'Picnic Supermarket MCP API');
};

subtest 'without a token a loopback client is served' => sub {
  my $t = load_app();

  @calls = ();
  $t->get_ok('/api/user')->status_is(200)->json_is('/firstname' => 'Erika');
  is_deeply \@calls, [qw(login get_user)], 'served from the account';
  $t->post_ok('/mcp' => json => \%mcp_initialize)->status_is(200);

  $t->get_ok('/openapi.json')
    ->status_is(200)
    ->json_hasnt('/components')
    ->json_hasnt('/security');
};

subtest 'without a token nothing but a loopback client is served' => sub {
  my $t = load_app();

  @calls = ();
  for my $header (qw(X-Forwarded-For X-Forwarded-Host X-Forwarded-Proto X-Real-IP Forwarded)) {
    $t->get_ok('/api/user' => { $header => 'for=203.0.113.9' })
      ->status_is(403, "request relayed by a proxy ($header)")
      ->json_like('/message' => qr/MCP_PICNIC_TOKEN/);
  }
  $t->post_ok('/mcp' => { 'X-Forwarded-For' => '203.0.113.9' } => json => \%mcp_initialize)->status_is(403);

  my $remote = '203.0.113.9';
  $t->app->hook(before_dispatch => sub { $_[0]->tx->remote_address($remote) });
  $t->get_ok('/api/user')->status_is(403, 'client from another host');
  $t->post_ok('/api/cart/clear')->status_is(403);
  $t->post_ok('/mcp' => json => \%mcp_initialize)->status_is(403);
  is_deeply \@calls, [], 'no rejected request reached the Picnic account';

  for my $address ('127.0.0.1', '127.8.9.10', '::1') {
    $remote = $address;
    $t->get_ok('/api/user')->status_is(200, "client on $address");
  }
};

subtest 'without a token the server only starts on loopback' => sub {
  my $t = load_app();

  my $start = sub {
    my $daemon = Mojo::Server::Daemon->new(listen => [@_], silent => 1);
    return eval { $t->app->server($daemon); 1 } ? '' : "$@";
  };

  for my $listen (
    ['http://*:3000'],
    ['http://0.0.0.0:3000'],
    ['http://[::]:3000'],
    ['http://192.0.2.10:3000'],
    ['https://picnic.example.com:443'],
    ['http+unix://%2Ftmp%2Fmcp-picnic.sock'],
    ['http://127.0.0.1:3000', 'http://*:3001'],
  ) {
    like $start->(@$listen), qr/MCP_PICNIC_TOKEN/, "refuses to start on @$listen";
  }

  for my $listen (
    ['http://127.0.0.1:3000'],
    ['http://127.0.0.2:8080'],
    ['http://[::1]:3000'],
    ['http://localhost:3000'],
    ['http://127.0.0.1:3000', 'http://[::1]:3000'],
  ) {
    is $start->(@$listen), '', "starts on @$listen";
  }
};

subtest 'with a token the server starts on any address' => sub {
  my $t      = load_app(MCP_PICNIC_TOKEN => $token);
  my $daemon = Mojo::Server::Daemon->new(listen => ['http://*:3000'], silent => 1);
  ok eval { $t->app->server($daemon); 1 }, 'starts on http://*:3000' or diag $@;
};

subtest 'the default listen address is loopback' => sub {
  my (undef, $listen) = load_app();
  is $listen, 'http://127.0.0.1:3000', 'no MOJO_LISTEN: loopback instead of every interface';

  (undef, $listen) = load_app(MOJO_LISTEN => 'http://192.0.2.10:8080');
  is $listen, 'http://192.0.2.10:8080', 'an explicit MOJO_LISTEN is kept';
};

done_testing;
