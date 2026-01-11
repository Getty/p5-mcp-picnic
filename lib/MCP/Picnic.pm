package MCP::Picnic;
# ABSTRACT: MCP Server for Picnic Supermarket API

use Moo;
use MCP::Server;
use WWW::Picnic;
use JSON::MaybeXS;
use Carp qw( croak );
use namespace::clean;

our $VERSION = '0.001';

has user => (
  is      => 'ro',
  lazy    => 1,
  default => sub { $ENV{PICNIC_USER} // croak "PICNIC_USER environment variable required" },
);

has pass => (
  is      => 'ro',
  lazy    => 1,
  default => sub { $ENV{PICNIC_PASS} // croak "PICNIC_PASS environment variable required" },
);

has country => (
  is      => 'ro',
  lazy    => 1,
  default => sub { $ENV{PICNIC_COUNTRY} // 'de' },
);

has picnic => (
  is      => 'ro',
  lazy    => 1,
  builder => '_build_picnic',
);

has json => (
  is      => 'ro',
  lazy    => 1,
  default => sub { JSON::MaybeXS->new(utf8 => 0, pretty => 1) },
);

has server => (
  is      => 'ro',
  lazy    => 1,
  builder => '_build_server',
);

has _auth_state => (
  is      => 'rw',
  default => sub { 'none' },  # none, pending_2fa, authenticated
);

sub _build_picnic {
  my ($self) = @_;
  return WWW::Picnic->new(
    user    => $self->user,
    pass    => $self->pass,
    country => $self->country,
  );
}

sub _to_json {
  my ($self, $data) = @_;
  return $self->json->encode($data);
}

sub _ensure_auth {
  my ($self) = @_;

  return 1 if $self->_auth_state eq 'authenticated';

  if ($self->_auth_state eq 'pending_2fa') {
    return { error => 1, message => "2FA-Verifizierung ausstehend! Bitte gib den SMS-Code ein, den du erhalten hast. Nutze dafuer das verify_2fa Tool." };
  }

  # Try to login
  my $login = eval { $self->picnic->login };
  if ($@) {
    return { error => 1, message => "Login fehlgeschlagen: $@" };
  }

  if ($login->requires_2fa) {
    $self->_auth_state('pending_2fa');
    eval { $self->picnic->generate_2fa_code };
    if ($@) {
      return { error => 1, message => "Konnte 2FA-Code nicht anfordern: $@" };
    }
    return {
      error   => 1,
      message => "2FA erforderlich! Ich habe dir eine SMS mit einem Verifizierungscode geschickt. Bitte gib den Code hier ein, damit ich ihn mit dem verify_2fa Tool verifizieren kann."
    };
  }

  $self->_auth_state('authenticated');
  return 1;
}

sub _article_to_hash {
  my ($self, $article) = @_;
  return {
    id            => $article->id,
    name          => $article->name,
    price         => $article->price,
    display_price => $article->display_price,
    unit_quantity => $article->unit_quantity,
    image_id      => $article->image_id,
  };
}

sub _cart_to_hash {
  my ($self, $cart) = @_;
  return {
    total_count   => $cart->total_count,
    total_price   => $cart->total_price,
    items         => $cart->items,
    delivery_slot => $cart->selected_slot,
  };
}

sub _slot_to_hash {
  my ($self, $slot) = @_;
  return {
    slot_id      => $slot->slot_id,
    window_start => $slot->window_start,
    window_end   => $slot->window_end,
    is_available => $slot->is_available,
    minimum_order_value => $slot->minimum_order_value,
  };
}

sub _user_to_hash {
  my ($self, $user) = @_;
  return {
    user_id   => $user->user_id,
    firstname => $user->firstname,
    lastname  => $user->lastname,
    address   => $user->address,
    phone     => $user->phone,
  };
}

sub _build_server {
  my ($self) = @_;

  my $server = MCP::Server->new(
    name    => 'Picnic',
    version => $VERSION,
  );

  # Tool: verify_2fa
  $server->tool(
    name        => 'verify_2fa',
    description => 'Verifiziere den 2FA-Code der per SMS gesendet wurde. Nutze dieses Tool nachdem der User den Code eingegeben hat.',
    input_schema => {
      type       => 'object',
      properties => {
        code => {
          type        => 'string',
          description => 'Der 6-stellige Code aus der SMS',
        },
      },
      required => ['code'],
    },
    code => sub {
      my ($tool, $args) = @_;

      unless ($self->_auth_state eq 'pending_2fa') {
        return "Keine 2FA-Verifizierung ausstehend. Login wird automatisch durchgefuehrt wenn noetig.";
      }

      my $result = eval { $self->picnic->verify_2fa_code($args->{code}) };
      if ($@) {
        return "2FA-Verifizierung fehlgeschlagen: $@";
      }

      $self->_auth_state('authenticated');
      return "Erfolgreich verifiziert! Du kannst jetzt alle Picnic-Funktionen nutzen.";
    },
  );

  # Tool: search_products
  $server->tool(
    name        => 'search_products',
    description => 'Suche nach Produkten im Picnic Supermarkt. Gibt Produkte mit Name, Preis und ID zurueck.',
    input_schema => {
      type       => 'object',
      properties => {
        query => {
          type        => 'string',
          description => 'Suchbegriff (z.B. "Milch", "Haribo", "Bio Eier")',
        },
      },
      required => ['query'],
    },
    code => sub {
      my ($tool, $args) = @_;

      my $auth = $self->_ensure_auth;
      return $auth->{message} if ref $auth && $auth->{error};

      my $results = eval { $self->picnic->search($args->{query}) };
      return "Suche fehlgeschlagen: $@" if $@;

      my @items = map { $self->_article_to_hash($_) } $results->all_items;
      return "Keine Produkte gefunden fuer '$args->{query}'" unless @items;

      return $self->_to_json(\@items);
    },
  );

  # Tool: get_product_details
  $server->tool(
    name        => 'get_product_details',
    description => 'Hole detaillierte Informationen zu einem Produkt anhand seiner ID.',
    input_schema => {
      type       => 'object',
      properties => {
        product_id => {
          type        => 'string',
          description => 'Die Produkt-ID (aus der Suche)',
        },
      },
      required => ['product_id'],
    },
    code => sub {
      my ($tool, $args) = @_;

      my $auth = $self->_ensure_auth;
      return $auth->{message} if ref $auth && $auth->{error};

      my $article = eval { $self->picnic->get_article($args->{product_id}) };
      return "Produkt nicht gefunden: $@" if $@;

      return $self->_to_json({
        id            => $article->id,
        name          => $article->name,
        price         => $article->price,
        price_info    => $article->price_info,
        description   => $article->description,
        unit_quantity => $article->unit_quantity,
        image_ids     => $article->image_ids,
        labels        => $article->labels,
      });
    },
  );

  # Tool: get_suggestions
  $server->tool(
    name        => 'get_suggestions',
    description => 'Hole Suchvorschlaege fuer einen teilweisen Suchbegriff.',
    input_schema => {
      type       => 'object',
      properties => {
        term => {
          type        => 'string',
          description => 'Teilweiser Suchbegriff (z.B. "Mil" fuer Milch-Vorschlaege)',
        },
      },
      required => ['term'],
    },
    code => sub {
      my ($tool, $args) = @_;

      my $auth = $self->_ensure_auth;
      return $auth->{message} if ref $auth && $auth->{error};

      my $suggestions = eval { $self->picnic->get_suggestions($args->{term}) };
      return "Vorschlaege fehlgeschlagen: $@" if $@;

      return $self->_to_json($suggestions);
    },
  );

  # Tool: get_cart
  $server->tool(
    name        => 'get_cart',
    description => 'Zeige den aktuellen Warenkorb mit allen Artikeln, Gesamtpreis und ausgewaehltem Lieferslot.',
    input_schema => {
      type       => 'object',
      properties => {},
    },
    code => sub {
      my ($tool, $args) = @_;

      my $auth = $self->_ensure_auth;
      return $auth->{message} if ref $auth && $auth->{error};

      my $cart = eval { $self->picnic->get_cart };
      return "Warenkorb konnte nicht geladen werden: $@" if $@;

      return $self->_to_json($self->_cart_to_hash($cart));
    },
  );

  # Tool: add_to_cart
  $server->tool(
    name        => 'add_to_cart',
    description => 'Fuege ein Produkt zum Warenkorb hinzu.',
    input_schema => {
      type       => 'object',
      properties => {
        product_id => {
          type        => 'string',
          description => 'Die Produkt-ID',
        },
        count => {
          type        => 'integer',
          description => 'Anzahl (Standard: 1)',
          default     => 1,
        },
      },
      required => ['product_id'],
    },
    code => sub {
      my ($tool, $args) = @_;

      my $auth = $self->_ensure_auth;
      return $auth->{message} if ref $auth && $auth->{error};

      my $count = $args->{count} // 1;
      my $cart = eval { $self->picnic->add_to_cart($args->{product_id}, $count) };
      return "Konnte nicht zum Warenkorb hinzufuegen: $@" if $@;

      return $self->_to_json({
        message => "Produkt hinzugefuegt ($count x)",
        cart    => $self->_cart_to_hash($cart),
      });
    },
  );

  # Tool: remove_from_cart
  $server->tool(
    name        => 'remove_from_cart',
    description => 'Entferne ein Produkt aus dem Warenkorb.',
    input_schema => {
      type       => 'object',
      properties => {
        product_id => {
          type        => 'string',
          description => 'Die Produkt-ID',
        },
        count => {
          type        => 'integer',
          description => 'Anzahl zu entfernen (Standard: 1)',
          default     => 1,
        },
      },
      required => ['product_id'],
    },
    code => sub {
      my ($tool, $args) = @_;

      my $auth = $self->_ensure_auth;
      return $auth->{message} if ref $auth && $auth->{error};

      my $count = $args->{count} // 1;
      my $cart = eval { $self->picnic->remove_from_cart($args->{product_id}, $count) };
      return "Konnte nicht aus Warenkorb entfernen: $@" if $@;

      return $self->_to_json({
        message => "Produkt entfernt ($count x)",
        cart    => $self->_cart_to_hash($cart),
      });
    },
  );

  # Tool: clear_cart
  $server->tool(
    name        => 'clear_cart',
    description => 'Leere den gesamten Warenkorb.',
    input_schema => {
      type       => 'object',
      properties => {},
    },
    code => sub {
      my ($tool, $args) = @_;

      my $auth = $self->_ensure_auth;
      return $auth->{message} if ref $auth && $auth->{error};

      my $cart = eval { $self->picnic->clear_cart };
      return "Warenkorb konnte nicht geleert werden: $@" if $@;

      return "Warenkorb geleert!";
    },
  );

  # Tool: get_delivery_slots
  $server->tool(
    name        => 'get_delivery_slots',
    description => 'Zeige verfuegbare Lieferzeitfenster.',
    input_schema => {
      type       => 'object',
      properties => {},
    },
    code => sub {
      my ($tool, $args) = @_;

      my $auth = $self->_ensure_auth;
      return $auth->{message} if ref $auth && $auth->{error};

      my $slots = eval { $self->picnic->get_delivery_slots };
      return "Lieferslots konnten nicht geladen werden: $@" if $@;

      my @available = map { $self->_slot_to_hash($_) } $slots->available_slots;
      return "Keine verfuegbaren Lieferslots" unless @available;

      return $self->_to_json(\@available);
    },
  );

  # Tool: set_delivery_slot
  $server->tool(
    name        => 'set_delivery_slot',
    description => 'Waehle einen Lieferslot fuer die Bestellung aus.',
    input_schema => {
      type       => 'object',
      properties => {
        slot_id => {
          type        => 'string',
          description => 'Die Slot-ID (aus get_delivery_slots)',
        },
      },
      required => ['slot_id'],
    },
    code => sub {
      my ($tool, $args) = @_;

      my $auth = $self->_ensure_auth;
      return $auth->{message} if ref $auth && $auth->{error};

      my $cart = eval { $self->picnic->set_delivery_slot($args->{slot_id}) };
      return "Lieferslot konnte nicht gesetzt werden: $@" if $@;

      return $self->_to_json({
        message => "Lieferslot ausgewaehlt!",
        cart    => $self->_cart_to_hash($cart),
      });
    },
  );

  # Tool: get_user
  $server->tool(
    name        => 'get_user',
    description => 'Zeige Informationen zum eingeloggten Benutzer (Name, Adresse, etc.).',
    input_schema => {
      type       => 'object',
      properties => {},
    },
    code => sub {
      my ($tool, $args) = @_;

      my $auth = $self->_ensure_auth;
      return $auth->{message} if ref $auth && $auth->{error};

      my $user = eval { $self->picnic->get_user };
      return "Benutzerinfo konnte nicht geladen werden: $@" if $@;

      return $self->_to_json($self->_user_to_hash($user));
    },
  );

  # Tool: get_categories
  $server->tool(
    name        => 'get_categories',
    description => 'Zeige Produktkategorien des Shops.',
    input_schema => {
      type       => 'object',
      properties => {
        depth => {
          type        => 'integer',
          description => 'Tiefe der Kategorien (0 = nur Hauptkategorien)',
          default     => 0,
        },
      },
    },
    code => sub {
      my ($tool, $args) = @_;

      my $auth = $self->_ensure_auth;
      return $auth->{message} if ref $auth && $auth->{error};

      my $depth = $args->{depth} // 0;
      my $categories = eval { $self->picnic->get_categories($depth) };
      return "Kategorien konnten nicht geladen werden: $@" if $@;

      return $self->_to_json($categories);
    },
  );

  return $server;
}

sub run_stdio {
  my ($self) = @_;
  $self = $self->new unless ref $self;
  $self->server->to_stdio;
}

1;

__END__

=head1 SYNOPSIS

  # Als stdio MCP Server (fuer Claude Desktop, etc.)
  use MCP::Picnic;
  MCP::Picnic->run_stdio;

  # Oder mit dem mitgelieferten Script:
  # mcp-picnic

  # Umgebungsvariablen setzen:
  export PICNIC_USER="deine@email.de"
  export PICNIC_PASS="dein-passwort"
  export PICNIC_COUNTRY="de"  # oder "nl"

=head1 DESCRIPTION

MCP::Picnic stellt einen MCP (Model Context Protocol) Server bereit, der
AI-Assistenten wie Claude Zugriff auf die Picnic Supermarkt API gibt.

Der Server unterstuetzt:

=over 4

=item * Produktsuche

=item * Warenkorb-Verwaltung (hinzufuegen, entfernen, leeren)

=item * Lieferzeitfenster anzeigen und auswaehlen

=item * Benutzerprofil anzeigen

=item * 2FA-Authentifizierung (interaktiv ueber den AI-Assistenten)

=back

=head1 2FA AUTHENTIFIZIERUNG

Picnic erfordert oft eine Zwei-Faktor-Authentifizierung per SMS. Der MCP Server
handhabt dies interaktiv:

1. Bei der ersten Anfrage wird automatisch ein Login versucht
2. Falls 2FA noetig ist, wird eine SMS an deine Handynummer geschickt
3. Der AI-Assistent fragt dich nach dem Code
4. Du gibst den Code ein, der Assistent verifiziert ihn
5. Alle weiteren Anfragen funktionieren normal

=head1 CLAUDE DESKTOP INTEGRATION

Fuege folgendes zu deiner Claude Desktop MCP-Konfiguration hinzu:

  {
    "mcpServers": {
      "picnic": {
        "command": "mcp-picnic",
        "env": {
          "PICNIC_USER": "deine@email.de",
          "PICNIC_PASS": "dein-passwort",
          "PICNIC_COUNTRY": "de"
        }
      }
    }
  }

=head1 AVAILABLE TOOLS

=head2 verify_2fa

Verifiziert den 2FA SMS-Code.

=head2 search_products

Sucht nach Produkten.

B<Parameter:> C<query> (string, required)

=head2 get_product_details

Holt Details zu einem Produkt.

B<Parameter:> C<product_id> (string, required)

=head2 get_suggestions

Holt Suchvorschlaege.

B<Parameter:> C<term> (string, required)

=head2 get_cart

Zeigt den aktuellen Warenkorb.

=head2 add_to_cart

Fuegt ein Produkt zum Warenkorb hinzu.

B<Parameter:> C<product_id> (string, required), C<count> (integer, default: 1)

=head2 remove_from_cart

Entfernt ein Produkt aus dem Warenkorb.

B<Parameter:> C<product_id> (string, required), C<count> (integer, default: 1)

=head2 clear_cart

Leert den Warenkorb.

=head2 get_delivery_slots

Zeigt verfuegbare Lieferzeitfenster.

=head2 set_delivery_slot

Waehlt einen Lieferslot aus.

B<Parameter:> C<slot_id> (string, required)

=head2 get_user

Zeigt Benutzerinformationen.

=head2 get_categories

Zeigt Produktkategorien.

B<Parameter:> C<depth> (integer, default: 0)

=head1 SEE ALSO

L<MCP::Server>, L<WWW::Picnic>

=cut
