#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

# Network-free tests for the MCP::Picnic auth state machine and auth gate.
# A hand-rolled fake stands in for WWW::Picnic so no real login, HTTP or 2FA
# SMS ever happens. The fake records which methods were called.

{
  package Fake::Picnic;
  sub new {
    my ($class, %args) = @_;
    return bless { calls => [], requires_2fa => $args{requires_2fa}, generate_failures => $args{generate_failures} // 0, verify_failures => $args{verify_failures} // 0 }, $class;
  }
  sub _record { push @{$_[0]{calls}}, $_[1] }
  sub calls { @{$_[0]{calls}} }

  sub login {
    my ($self) = @_;
    $self->_record('login');
    return Fake::LoginResult->new($self->{requires_2fa});
  }
  sub generate_2fa_code {
    my ($self) = @_;
    $self->_record('generate_2fa_code');
    die "SMS gateway down\n" if $self->{generate_failures}-- > 0;
    return 1;
  }
  sub verify_2fa_code {
    my ($self, $code) = @_;
    $self->_record("verify_2fa_code:$code");
    die "code expired\n" if $self->{verify_failures}-- > 0;
    return 1;
  }
}

{
  package Fake::LoginResult;
  sub new { bless { requires_2fa => $_[1] ? 1 : 0 }, $_[0] }
  sub requires_2fa { $_[0]{requires_2fa} }
}

use MCP::Picnic;

sub build_mcp {
  my (%args) = @_;
  return MCP::Picnic->new(
    user   => 'dummy@example.com',
    pass   => 'dummy-pass',
    picnic => Fake::Picnic->new(%args)
  );
}

# Helper: fetch a registered MCP::Tool instance by name.
sub tool_named {
  my ($mcp, $name) = @_;
  for my $tool (@{$mcp->server->tools}) {
    return $tool if $tool->name eq $name;
  }
  return undef;
}

# --- Fresh object starts in state 'none' ---------------------------------
{
  my $mcp = build_mcp(requires_2fa => 0);
  is $mcp->_auth_state, 'none', 'fresh object starts in state none';
}

# --- login without 2FA goes straight to authenticated --------------------
{
  my $mcp = build_mcp(requires_2fa => 0);
  my $gate = $mcp->_ensure_auth;
  is $gate, 1, '_ensure_auth returns 1 when login succeeds without 2FA';
  is $mcp->_auth_state, 'authenticated', 'state is authenticated after plain login';
  is_deeply [$mcp->picnic->calls], ['login'],
    'only login was called, no 2FA code generated';
}

# --- login requiring 2FA transitions to pending_2fa ----------------------
{
  my $mcp = build_mcp(requires_2fa => 1);
  my $gate = $mcp->_ensure_auth;
  ok ref $gate eq 'HASH' && $gate->{error},
    '_ensure_auth returns an error hash when 2FA is required';
  is $mcp->_auth_state, 'pending_2fa', 'state is pending_2fa after 2FA-required login';
  is_deeply [$mcp->picnic->calls], ['login', 'generate_2fa_code'],
    'login then generate_2fa_code were called';
}

# --- while pending_2fa, _ensure_auth keeps gating (no re-login) -----------
{
  my $mcp = build_mcp(requires_2fa => 1);
  $mcp->_ensure_auth;                     # -> pending_2fa
  my $before = [$mcp->picnic->calls];
  my $gate = $mcp->_ensure_auth;          # second call while pending
  ok ref $gate eq 'HASH' && $gate->{error},
    '_ensure_auth still gates while pending_2fa';
  is_deeply [$mcp->picnic->calls], $before,
    'no extra backend calls while pending_2fa';
  is $mcp->_auth_state, 'pending_2fa', 'state stays pending_2fa';
}

# --- authenticated state short-circuits to 1 -----------------------------
{
  my $mcp = build_mcp(requires_2fa => 0);
  $mcp->_auth_state('authenticated');
  is $mcp->_ensure_auth, 1, '_ensure_auth returns 1 when already authenticated';
  is_deeply [$mcp->picnic->calls], [],
    'no backend call when already authenticated';
}

# --- auth gate: a non-verify tool blocks while unauthenticated -----------
{
  my $mcp = build_mcp(requires_2fa => 1);
  my $tool = tool_named($mcp, 'search_products');
  ok $tool, 'search_products tool is registered';

  my $result = $tool->call({ query => 'milk' }, {});
  ok ref $result eq 'HASH', 'tool call returns a hashref result';
  ok $result->{isError}, 'unauthenticated search_products returns isError true';

  # It must have stopped at the auth gate, never reaching the search backend.
  my %seen = map { $_ => 1 } $mcp->picnic->calls;
  ok !grep({ /^search/ } $mcp->picnic->calls),
    'backend search was never reached behind the auth gate';
}

# --- verify_2fa: pending_2fa + good code -> authenticated, success -------
{
  my $mcp = build_mcp(requires_2fa => 1);
  $mcp->_ensure_auth;                     # -> pending_2fa
  is $mcp->_auth_state, 'pending_2fa', 'precondition: pending_2fa before verify';

  my $tool = tool_named($mcp, 'verify_2fa');
  ok $tool, 'verify_2fa tool is registered';

  my $result = $tool->call({ code => '123456' }, {});
  ok ref $result eq 'HASH', 'verify_2fa returns a hashref result';
  ok !$result->{isError}, 'successful verify_2fa returns isError false';
  is $mcp->_auth_state, 'authenticated', 'state is authenticated after verify_2fa';
  ok grep({ $_ eq 'verify_2fa_code:123456' } $mcp->picnic->calls),
    'verify_2fa_code was called with the provided code';
}

# --- a failed SMS request must not leave the state stuck in pending_2fa --
{
  my $mcp = build_mcp(requires_2fa => 1, generate_failures => 1);
  my $gate = $mcp->_ensure_auth;
  like $gate->{message}, qr/Could not request 2FA code/, 'SMS request failure is reported';
  is $mcp->_auth_state, 'none', 'state falls back to none when generate_2fa_code dies';

  $gate = $mcp->_ensure_auth;
  like $gate->{message}, qr/2FA required/, 'next call retries the login and requests a new code';
  is $mcp->_auth_state, 'pending_2fa', 'state is pending_2fa once the SMS was sent';
  is_deeply [$mcp->picnic->calls], [('login', 'generate_2fa_code') x 2],
    'login and code request were repeated';
}

# --- a failed verification (expired code) restarts the login -------------
{
  my $mcp = build_mcp(requires_2fa => 1, verify_failures => 1);
  $mcp->_ensure_auth;
  my $tool = tool_named($mcp, 'verify_2fa');
  my $result = $tool->call({ code => '000000' }, {});
  ok $result->{isError}, 'failed verify_2fa returns isError true';
  is $mcp->_auth_state, 'none', 'state falls back to none after a failed verification';

  my $gate = $mcp->_ensure_auth;
  is $mcp->_auth_state, 'pending_2fa', 'next call logs in again and requests a fresh code';
  is scalar(grep { $_ eq 'generate_2fa_code' } $mcp->picnic->calls), 2,
    'a second SMS was requested';
}

done_testing;
