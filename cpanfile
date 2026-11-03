requires 'perl', '5.020';
requires 'JSON::MaybeXS', '1.004000';
requires 'MCP', '0.06';
requires 'Mojolicious', '9.0';
requires 'Moo', '2.000000';
requires 'namespace::clean', '0.27';
requires 'Path::Tiny', '0.100';
requires 'Term::ReadKey';
requires 'WWW::Picnic', '0.101';

on test => sub {
  requires 'MCP', '0.15';
  requires 'Test::More', '1.302015';
};

# MCP loads JSON::Schema::Tiny, which loads strictures when AUTHOR_TESTING is
# set - and dzil test sets it.
on develop => sub {
  requires 'strictures', '2';
};
