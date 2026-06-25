#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

# Network-free tests for tool registration and the entity projection helpers.
# The picnic attribute is stubbed so constructing the server never logs in or
# touches the network.

{
  package Fake::Picnic;
  sub new { bless {}, shift }
}

use MCP::Picnic;

sub build_mcp {
  return MCP::Picnic->new(
    user   => 'dummy@example.com',
    pass   => 'dummy-pass',
    picnic => Fake::Picnic->new
  );
}

# --- The server builds and exposes every expected tool name --------------
{
  my $mcp = build_mcp();
  my $server = $mcp->server;
  isa_ok $server, 'MCP::Server', 'server builds';

  my @expected = qw(
    verify_2fa
    search_products
    get_product_details
    get_suggestions
    get_cart
    add_to_cart
    remove_from_cart
    clear_cart
    get_delivery_slots
    set_delivery_slot
    get_user
    get_categories
  );

  my @names = map { $_->name } @{$server->tools};
  is scalar(@names), scalar(@expected), 'twelve tools are registered';

  my %got = map { $_ => 1 } @names;
  for my $name (@expected) {
    ok $got{$name}, "tool '$name' is registered";
  }
}

# --- _article_to_hash projects the WWW::Picnic article shape -------------
{
  package Fake::Article;
  sub new { bless {}, shift }
  sub id            { 'art-1' }
  sub name          { 'Whole Milk' }
  sub price         { 119 }
  sub display_price { '1.19' }
  sub unit_quantity { '1 L' }
  sub image_id      { 'img-1' }
}
{
  my $mcp = build_mcp();
  my $hash = $mcp->_article_to_hash(Fake::Article->new);
  is_deeply $hash, {
    id            => 'art-1',
    name          => 'Whole Milk',
    price         => 119,
    display_price => '1.19',
    unit_quantity => '1 L',
    image_id      => 'img-1'
  }, '_article_to_hash projects the expected fields';
}

# --- _cart_to_hash -------------------------------------------------------
{
  package Fake::Cart;
  sub new { bless {}, shift }
  sub total_count   { 3 }
  sub total_price   { 357 }
  sub items         { [qw(a b c)] }
  sub selected_slot { 'slot-9' }
}
{
  my $mcp = build_mcp();
  my $hash = $mcp->_cart_to_hash(Fake::Cart->new);
  is_deeply $hash, {
    total_count   => 3,
    total_price   => 357,
    items         => [qw(a b c)],
    delivery_slot => 'slot-9'
  }, '_cart_to_hash projects the expected fields';
}

# --- _slot_to_hash -------------------------------------------------------
{
  package Fake::Slot;
  sub new { bless {}, shift }
  sub slot_id             { 'slot-9' }
  sub window_start        { '2026-06-20T10:00:00' }
  sub window_end          { '2026-06-20T11:00:00' }
  sub is_available        { 1 }
  sub minimum_order_value { 3500 }
}
{
  my $mcp = build_mcp();
  my $hash = $mcp->_slot_to_hash(Fake::Slot->new);
  is_deeply $hash, {
    slot_id             => 'slot-9',
    window_start        => '2026-06-20T10:00:00',
    window_end          => '2026-06-20T11:00:00',
    is_available        => 1,
    minimum_order_value => 3500
  }, '_slot_to_hash projects the expected fields';
}

# --- _user_to_hash -------------------------------------------------------
{
  package Fake::User;
  sub new { bless {}, shift }
  sub user_id   { 'usr-1' }
  sub firstname { 'Ada' }
  sub lastname  { 'Lovelace' }
  sub address   { 'Analytical Engine St 1' }
  sub phone     { '+490000000000' }
}
{
  my $mcp = build_mcp();
  my $hash = $mcp->_user_to_hash(Fake::User->new);
  is_deeply $hash, {
    user_id   => 'usr-1',
    firstname => 'Ada',
    lastname  => 'Lovelace',
    address   => 'Analytical Engine St 1',
    phone     => '+490000000000'
  }, '_user_to_hash projects the expected fields';
}

done_testing;
