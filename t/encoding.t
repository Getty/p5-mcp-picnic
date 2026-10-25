#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test::More;
use Mojo::JSON qw(encode_json decode_json from_json);
use MCP::Server::Context;
use MCP::Server::Legacy qw(legacy_request);

# Tool results travel through MCP::Server's transports, which encode the whole
# response to UTF-8 themselves. The payload inside text_result must therefore
# be a character string, or non-ASCII characters arrive double-encoded.

{
  package Fake::Article;
  sub new { bless {}, shift }
  sub id            { 'art-1' }
  sub name          { "Müsli €" }
  sub price         { 299 }
  sub display_price { '2,99 €' }
  sub unit_quantity { '500 g' }
  sub image_id      { 'img-1' }
}
{
  package Fake::Results;
  sub new { bless {}, shift }
  sub all_items { Fake::Article->new }
}
{
  package Fake::Picnic;
  sub new { bless {}, shift }
  sub search { Fake::Results->new }
}

use MCP::Picnic;

my $mcp = MCP::Picnic->new(
  user   => 'dummy@example.com',
  pass   => 'dummy-pass',
  picnic => Fake::Picnic->new,
);
$mcp->_auth_state('authenticated');

my $response = $mcp->server->handle({
  jsonrpc => '2.0',
  id      => 1,
  method  => 'tools/call',
  params  => { name => 'search_products', arguments => { query => 'Müsli' } },
},
  MCP::Server::Context->new(legacy => legacy_request(undef, {}), stream => sub {}, transport => undef),
);

# The stdio transport puts the response on the wire with encode_json; the
# client decodes that and parses the text payload. The text is already
# characters, so it is parsed as characters (from_json), not as bytes.
my $wire   = encode_json($response);
my $client = decode_json($wire);
my $items  = from_json($client->{result}{content}[0]{text});

is $items->[0]{name},          "Müsli €", 'product name survives the wire';
is $items->[0]{display_price}, "2,99 €",  'display price survives the wire';

done_testing;
