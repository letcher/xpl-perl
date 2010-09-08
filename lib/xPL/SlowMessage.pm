package xPL::SlowMessage;

=head1 NAME

xPL::Message - Perl extension for xPL message base class

=head1 SYNOPSIS

  use xPL::Message;

  my $msg = xPL::Message->new(message_type => 'xpl-stat',
                              head =>
                              {
                               hop => 1,
                               source => 'acme-lamp.livingroom',
                               target => '*',
                              },
                              class => 'hbeat.app',
                              body =>
                              [
                               interval => 10,
                               port => 12345,
                               remote_ip => '127.0.0.1',
                               extra => 'value in my extra field',
                              ],
                             );

  # let's leave out some fields and let them use the defaults
  $msg = xPL::Message->new(head =>
                           {
                            source => 'acme-lamp.livingroom',
                           },
                           class => 'hbeat.app',
                           body =>
                           [
                            remote_ip => '127.0.0.1',
                            extra => 'value in my extra field',
                           ],
                          );

=head1 DESCRIPTION

This module creates an xPL message.

=head1 METHODS

=cut

use 5.006;
use strict;
use warnings;
use English qw/-no_match_vars/;
use File::Find;
eval { require YAML::Syck; import YAML::Syck qw/LoadFile/; };
if ($@) {
  eval { require YAML; import YAML qw/LoadFile/; };
  die "Failed to load YAML::Syck or YAML module: $@\n" if ($@);
}
use xPL::Validation;

use xPL::Base;
#use AutoLoader qw(AUTOLOAD);

our @ISA = qw(xPL::Base);
our %EXPORT_TAGS = ( 'all' => [ qw() ] );
our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );
our @EXPORT = qw();
our $VERSION = qw/$Revision$/[1];

our %specs = ();
our %modules = ();

our $LF = "\012";
our $EMPTY = q{};
our $DOT = q{.};
our $SPACE= q{ };
our $STAR = q{*};
our $EQUALS = q{=};
our $DOUBLE_COLON = q{::};
our $SPACE_DASH_SPACE = q{ - };
our $COMMA = q{,};
our $OPEN_SQUARE_BRACKET = q{[};
our $CLOSE_SQUARE_BRACKET = q{]};
our %MESSAGE_TYPES = map { $_ => 1 } qw/xpl-cmnd xpl-stat xpl-trig/;

__PACKAGE__->make_readonly_accessor(qw/class/);

my $path = $INC{'xPL/SlowMessage.pm'};
$path =~ s!([/\\])SlowMessage\.pm$!${1}schema!;
my @paths = ($path);
push @paths, $ENV{XPL_SCHEMA_PATH} if (exists $ENV{XPL_SCHEMA_PATH});
find({
      wanted =>
      sub {
        return unless ($File::Find::name =~
                       m![/\\]([^\\/\.]+)\.([^\\/\.]+)\.yaml$!);
        my $class = $1;
        my $class_type = $2;
        # print STDERR "$class.$class_type\n";
        my $spec;
        eval { $spec = LoadFile($File::Find::name); };
        if ($EVAL_ERROR) {
          die "Failed to read schema from $File::Find::name\n",$EVAL_ERROR,"\n";
        }
        $specs{$class.$DOT.$class_type} = $spec;
      },
      no_chdir => 1,
     }, @paths);

=head2 C<new(%parameter_hash)>

The constructor creates a new xPL::SlowMessage object.  The constructor
takes a parameter hash as arguments.  Valid parameters in the hash
are:

=over 4

=item message_type

  The message type identifier.  Valid values are 'xpl-cmnd',
  'xpl-stat' and 'xpl-trig', for each of the three styles of xPL
  Message.

=item class

  The class or schema of the message.  This should be the
  full schema name, such as 'hbeat.basic'.  This field is used
  to determine the type of xPL Message object that will actually
  be instantiated and returned to the caller.

=back

It returns a blessed reference when successful or undef otherwise.

=cut

sub new {
  my $pkg = shift;

  my %p = @_;
  exists $p{strict} or $p{strict} = 1;

  my $class;
  my $class_type;
  defined $p{class} or $pkg->argh(q{requires 'class' parameter});
  unless ($p{class} =~ /^([A-Z0-9]{1,8})\.([A-Z0-9]{1,8})$/i) {
    $pkg->argh("'class' parameter, ".$p{class}.", is invalid.\n".
               'It must be up to 8 characters (from A-Z, a-z and 0-9), a dot, '
               .'and then up to 8 more characters (from A-Z, a-z and 0-9).');
  }
  $class = $1;
  $class_type = $2;

  my $module = $pkg.$DOUBLE_COLON.(lc $class).$DOUBLE_COLON.(lc $class_type);
  if (exists $specs{$p{class}} && !exists $modules{$module}) {
    make_class($class, $class_type)
  }
  if (!exists $p{message_type}) {
    my $default_message_type =
      $modules{$module} ? $module->default_message_type() :
        $pkg->default_message_type();
    $p{message_type} = $default_message_type
      if (defined $default_message_type);
  }

  # process message_type
  exists $p{message_type} or $pkg->argh(q{requires 'message_type' parameter});
  my $message_type = $p{message_type};
  delete $p{message_type};

  my $mt = lc $message_type;
  $mt =~ s/-//;
  $module .= $DOUBLE_COLON.$mt;

  unless (exists $modules{$module}) {
    $module = $pkg;
    $pkg->ouch("New message type ", $p{class}, "\n")
      if (exists $ENV{XPL_MSG_WARN});
  } else {
    $module = $modules{$module};
  }

  my $self = {};
  bless $self, $module;

  $self->{_verbose} = $p{verbose}||0;
  $self->{_strict} = $p{strict};

  $self->{_class} = $p{class};
  $self->message_type($message_type);

  if ($p{head_content}) {
    $self->{_head_content} = $p{head_content};
  } else {
    exists $p{head} or $p{head} = {};
    $self->parse_head_parameters($p{head}, $p{head_order});
  }

  if ($p{body_content}) {
    $self->{_body_content} = $p{body_content};
  } else {
    exists $p{body} or $p{body} = [];
    $self->parse_body_parameters($p{body});
  }
  return $self;
}

=head2 C<new_from_payload( $message )>

This is a constructor that takes the string of an xPL message and
constructs an xPL::SlowMessage object from it.

=cut

sub new_from_payload {
  my %r = ();
  my ($head, $body, $null) = split /\n}\n/, $_[1], 3;
  unless (defined $head) {
    xPL::SlowMessage->argh('Message badly formed: empty?');
  }
  unless (defined $body) {
    xPL::SlowMessage->argh('Message badly formed: failed to split head and body');
  }
  unless (defined $null) {
    xPL::SlowMessage->ouch('Message badly terminated: missing final eol char?');
    $body =~ s/\n}$//;
  }
  if ($null) {
    xPL::SlowMessage->ouch("Trailing trash: $null\n");
  }
  unless ($head =~ /^(.*?)\n\{\n(.*)$/s) {
    xPL::SlowMessage->argh("Invalid header: $head\n");
  }
  $r{message_type} = $1;
  $r{head_content} = $2;

  unless ($body =~ /^(.*?)\n\{\n?(.*)$/s) {
    xPL::SlowMessage->argh("Invalid body: $body\n");
  }
  $r{body_content} = $2;
  $r{class} = $1;
  return $_[0]->new(strict => 0, %r);
}

sub _parse_head {
  my %r;
  foreach (split /\n/, $_[0]->{_head_content}) {
    my ($k, $v) = split /=/, $_, 2;
    $k =~ s/-/_/g;
    $r{head}->{$k} = $v;
    push @{$r{head_order}}, $k;
  }
  delete $_[0]->{_head_content};
  $_[0]->parse_head_parameters($r{head}, $r{head_order});
}

sub _parse_body {
  my @body;
  foreach (split /\n/, $_[0]->{_body_content}) {
    my ($k, $v) = split /=/, $_, 2;
    $k =~ s/-/_/g;
    push @body, $k, $v;
  }
  delete $_[0]->{_body_content};
  $_[0]->parse_body_parameters(\@body);
}

=head2 C<field_spec()>

This is the default field specification.  It is empty.  Specific
message classes are intended to override this method.

=cut

sub field_spec {
  []
}

=head2 C<spec()>

This is the default message specification.  It is empty.  Specific
message classes are intended to override this method.

=cut

sub spec {
  {}
}

=head2 C<parse_head_parameters( $head_hash_ref, $head_order )>

This method is called by the constructor to process the fields of the
header of the message.

=cut

sub parse_head_parameters {
  my ($self, $head, $head_order) = @_;
  $self->{_head_order} = $head_order || [qw/hop source target/];

  # process fields from the header
  foreach ([ hop => 1 ],
           [ source => undef ],
           [ target => $STAR ],
          ) {
    my ($param, $default) = @$_;
    my $value;
    if (exists $head->{$param}) {
      $value = $head->{$param};
    } else {
      if (defined $default) {
        $value = $default;
      } else {
        $self->argh("requires '$param' parameter");
      }
    }
    $self->$param($value);
  }
  return 1;
}

=head2 C<parse_body_parameters( $body_hash_ref )>

This method is called by the constructor to process the fields of the
body of the message according to the field specification for the
message type.

=cut

sub parse_body_parameters {
  my ($self, $body_array) = @_;
  my $body = $self->{_body} = {};
  my $body_order = $self->{_body_order} = [];
  my $i = 0;
  while ($i < scalar @$body_array) {
    my $k = $body_array->[$i++];
    my $v = $body_array->[$i++];
    if (exists $body->{$k}) {
      if (ref $body->{$k}) {
        push @{$body->{$k}}, $v;
      } else {
        $body->{$k} = [$body->{$k}, $v];
      }
    } else {
      $body->{$k} = $v;
      push @{$body_order}, $k;
    }
  }
  my $spec = $self->field_spec();
  my %processed = ();
  foreach my $field_rec (@$spec) {
    $self->process_field_record($body, $field_rec, \%processed);
  }
  $self->{_extra_order} = [];
  foreach ($body_order ? @{$body_order} : sort keys %{$body}) {
    next if (exists $processed{$_});
    $self->extra_field($_, $body->{$_});
  }
  return 1;
}

=head2 C<process_field_record( $body_hash_ref, $field_record_hash_ref )>

This method is called by the constructor to process a single field
in body of the message according to the field specification for the
message type.

=cut

sub process_field_record {
  my $self = shift;
  my $body = shift;
  my $rec = shift;
  my $processed = shift;
  my $name = $rec->{name};
  unless (exists $body->{$name}) {
    if (exists $rec->{default}) {
      $body->{$name} = $rec->{default};
    } elsif (exists $rec->{required}) {
      if ($self->{_strict}) {
        $self->argh("requires '$name' parameter in body");
      } else {
        $self->ouch("requires '$name' parameter in body");
      }
    } else {
      return 1;
    }
  }
  if ($self->{_strict}) {
    $self->$name($body->{$name});
  } else {
    $self->{_body}->{$name} = $body->{$name};
  }
  $processed->{$name}++;
  return 1;
}

=head2 C<default_message_type()>

This method returns the default message type.  It is undefined for
the base class, but it can be overriden.

=cut

sub default_message_type {
  return;
}

=head2 C<summary()>

This method returns a string containing a summary of the xPL message.
It is intended for use when logging.

=cut

sub summary {
  my $self = shift;
  $self->_parse_head() if ($self->{_head_content});
  sprintf
    '%s/%s: %s -> %s %s',
      $self->{_message_type},
        $self->{_class}, $self->{_source}, $self->{_target},
            $self->body_summary();
}

=head2 C<body_summary()>

This method returns a string containing a summary of the fields from
the body of the xPL message.

=cut

sub body_summary {
  my $self = shift;
  my $str = $self->body_content;
  $str =~ s/^[^=]+=//mg;
  $str =~ s!$LF$!!;
  $str =~ s!$LF!/!g;
  $str;
}

=head2 C<pretty_print()>

This method returns a string containing a summary of the xPL message.
It is intended for use when logging.  This method is intended to be
overriden so that specific messages can append brief relevant data
to the common components of the summary.

=cut

sub pretty_print {
  my $self = shift;
  $self->_parse_head() if ($self->{_head_content});
  my $str =
    sprintf
      '%s/%s.%s: %s -> %s',
      $self->{_message_type},
      $self->{_class}, $self->{_class_type},
      $self->{_source}, $self->{_target};
  my $spec = $self->spec();
  $self->_parse_body() if ($self->{_body_content});
  if ($spec->{summary}) {
    $str .= $SPACE_DASH_SPACE;
    foreach my $field (@{$spec->{summary}}) {
      my $name = $field->{name};
      next unless (exists $self->{'_body'}->{$name});
      $str .= $field->{prefix} if ($field->{prefix});
      my $v = $self->{'_body'}->{$name};
      if ((ref $v) eq 'ARRAY') {
        $v = $OPEN_SQUARE_BRACKET.(join $COMMA, @$v).$CLOSE_SQUARE_BRACKET;
      }
      $str .= $v;
      $str .= $field->{suffix} if ($field->{suffix});
    }
  }
  return $str;
}

=head2 C<string()>

This method returns the xPL message string.  It is made up of the
L<head_string()> and L<body_string()>.

=cut

sub string {
  my $self = shift;
  $self->head_string(@_).$self->body_string(@_);
}

=head2 C<head_string()>

This method returns the string that makes up the head part of the xPL
message.

=cut

sub head_string {
  my $h = $_[0]->{_message_type}."$LF\{$LF";
  if (defined $_[0]->{_head_content}) {
    $h .= $_[0]->{_head_content}.$LF;
  } else {
    foreach (@{$_[0]->{_head_order}}) {
      $h .= $_.$EQUALS.$_[0]->{'_'.$_}.$LF;
    }
  }
  $h .= "}$LF";
  return $h;
}

=head2 C<body_string()>

This method returns the string that makes up the body part of the xPL
message.

=cut

sub body_string {
  $_[0]->{_class}."$LF\{$LF".$_[0]->body_content."}$LF";
}

=head2 C<body_content()>

This method returns the string that makes up the fields of the body
part of the xPL message.

=cut

sub body_content {
  return $_[0]->{_body_content}.$LF if (defined $_[0]->{_body_content});
  my $b = $EMPTY;
  foreach ($_[0]->body_fields()) {
    my $v = $_[0]->field($_);
    my $n = $_;
    $n = 'remote-ip' if ($_ eq 'remote_ip');
    foreach ((ref $v) ? @{$v} : ($v)) {
      $b .= "$n=".$_."$LF";
    }
  }
  $b;
}

=head2 C<strict( [ $new_strictness ] )>

This method returns the strictness setting for this message.  If the
optional new value argument is present, then this method updates the
message type identifier with the new value before it returns.

Strictness defines whether or not the message is validated harshly or
not.  Typically outgoing messages would have strictness turned on and
incoming messages would not.

=cut

sub strict {
  return $_[0]->{_strict} unless (@_ > 1);
  $_[0]->{_strict} = $_[1];
}

=head2 C<message_type( [ $new_message_type ] )>

This method returns the message type identifier.  If the optional new
value argument is present, then this method updates the message type
identifier with the new value before it returns.

=cut

sub message_type {
  return $_[0]->{_message_type} unless (@_ > 1);
  my $value = $_[1];
  if ($_[0]->{_strict} and !exists $MESSAGE_TYPES{$value}) {
    $_[0]->argh("message type identifier, $value, is invalid.\n".
                'It should be one of xpl-cmnd, xpl-stat or xpl-trig.');
  }
  $_[0]->{_message_type} = $value;
}

=head2 C<hop( [ $new_hop ] )>

This method returns the hop count.  If the optional new value argument
is present, then this method updates the hop count to the new value
before it returns.

=cut

sub hop {
  my $self = shift;
  $self->_parse_head() if ($self->{_head_content});
  if (@_) {
    my $value = $_[0];
    unless (!$self->{_strict} || $value =~ /^[1-9]$/) {
      $self->argh("hop count, $value, is invalid.\n".
                  'It should be a value from 1 to 9');
    }
    $self->{_hop} = $value;
  }
  return $self->{_hop};
}

=head2 C<source( [ $new_source ] )>

This method returns the source id.  If the optional new value argument
is present, then this method updates the source id to the new value
before it returns.

=cut

sub source {
  my $self = shift;
  $self->_parse_head() if ($self->{_head_content});
  if (@_) {
    my $value = $_[0];
    my $valid = valid_id($value);
    unless (!$self->{_strict} || $valid eq 'valid') {
      $self->argh("source, $value, is invalid.\n$valid");
    }
    $self->{_source} = $value;
  }
  return $self->{_source};
}

=head2 C<target( [ $new_target ] )>

This method returns the target id.  If the optional new value argument
is present, then this method updates the target id to the new value
before it returns.

=cut

sub target {
  my $self = shift;
  $self->_parse_head() if ($self->{_head_content});
  if (@_) {
    my $value = $_[0];
    if ($value ne $STAR) {
      my $valid = valid_id($value);
      unless (!$self->{_strict} || $valid eq 'valid') {
        $self->argh("target, $value, is invalid.\n$valid");
      }
    }
    $self->{_target} = $value;
  }
  return $self->{_target};
}

=head2 C<class()>

This method returns the class.

=head2 C<class_type()>

This method returns the class type.

=head2 C<valid_id( $identifier )>

This is a helper function (not a method) that return the string
'valid' if the given identifier is valid.  Otherwise it returns a
string with details of why the identifier is invalid.

=cut

sub valid_id {
  unless ($_[0] =~ m!^(.*)-(.*)\.(.*)$!) {
    return q{Invalid format - should be 'vendor-device.instance'.};
  }
  my ($vendor, $device, $instance) = ($1, $2, $3);
  unless ($vendor =~ /^[A-Z0-9]{1,8}$/i) {
    return 'Invalid vendor id - maximum of 8 chars from A-Z, a-z, and 0-9.';
  }
  unless ($device =~ /^[A-Z0-9]{1,8}$/i) {
    return 'Invalid device id - maximum of 8 chars from A-Z, a-z, and 0-9.';
  }
  unless ($instance =~ /^[A-Z0-9]{1,16}$/i) {
    return 'Invalid instance id - maximum of 16 chars from A-Z, a-z, and 0-9.';
  }
  return 'valid';
}

=head2 C<field( $field )>

Returns the value of a field.

=cut

sub field {
  my ($self, $field) = @_;
  $self->_parse_body() if ($self->{_body_content});
  exists $self->{_body}->{$field}
    ? $self->{_body}->{$field}
      : $self->{_extra}->{$field}
}

=head2 C<extra_field( $field, [ $value ] )>

This method returns the value of the extra field from the message
body.  If the optional new value argument is present, then this method
updates the extra field with the new value before it returns.

=cut

sub extra_field {
  my $self = shift;
  my $key = shift;
  $self->_parse_body() if ($self->{_body_content});
  if (@_) {
    push @{$self->{_extra_order}}, $key unless (exists $self->{_extra}->{$key});
    $self->{_extra}->{$key} = $_[0];
  }
  return $self->{_extra}->{$key};
}

=head2 C<extra_fields()>

This method returns the names of the extra fields present in this
message.

=cut

sub extra_fields {
  $_[0]->_parse_body() if ($_[0]->{_body_content});
  return @{$_[0]->{_extra_order}};
}

=head2 C<extra_field_string()>

This method returns a formatted string that forms the part of the xPL
message body that contains the extra fields.

=cut

sub extra_field_string {
  $_[0]->_parse_body() if ($_[0]->{_body_content});
  my $b = $EMPTY;
  foreach my $k (@{$_[0]->{_extra_order}}) {
    my $v = $_[0]->{_extra}->{$k};
    foreach ((ref $v) ? @{$v} : ($v)) {
      $b .= $k.$EQUALS.$_.$LF;
    }
  }
  return $b;
}

=head2 C<body_fields()>

This method returns the fields that are in the body of this message.

=cut

sub body_fields {
  $_[0]->_parse_body() if (exists $_[0]->{_body_content});
  @{$_[0]->{_body_order}}
}

=head2 C<make_class($class, $class_type)>

=cut

sub make_class {
  my ($class, $class_type) = @_;
  my $spec = $specs{$class.$DOT.$class_type};
  my $parent =
    __PACKAGE__.$DOUBLE_COLON.$class.$DOUBLE_COLON.$class_type;
  $modules{$parent} = $parent;
  my $isa = $parent.'::ISA';
  no strict qw/refs/;
  *{$isa} = [qw/xPL::SlowMessage/];
  if (exists $spec->{default_message_type}) {
    my $dmt = $parent.'::default_message_type';
    *{$dmt} =
      sub {
        $spec->{default_message_type};
      };
  }
  use strict qw/refs/;
  foreach my $message_type (keys %{$spec->{types}}) {
    my $mt = $message_type;
    $mt =~ s/-//;
    my $module = $parent.$DOUBLE_COLON.$mt;
    my $isa = $module.'::ISA';
    no strict qw/refs/;
    *{$isa} = [$parent];
    my $s = $module.'::spec';
    *{$s} =
      sub {
        $spec->{types}->{$message_type}
      };
    if (exists $spec->{types}->{$message_type}->{fields}) {
      my $fs = $module.'::field_spec';
      *{$fs} =
        sub {
          $spec->{types}->{$message_type}->{fields}
        };
    }
    use strict qw/refs/;
    $module->make_body_fields();
    $modules{$module} = $module;
  }
  return 1;
}

=head2 C<make_body_fields( )>

This method populates the symbol table.  It creates the methods for
the fields listed in the L<field_spec> for the message sub-classes.
It also creates a C<body_fields> method from the specification.

=cut

sub make_body_fields {
  my @f = ();
  foreach my $rec (@{$_[0]->field_spec()}) {
    $_[0]->make_body_field($rec);
    push @f, $rec->{name};
  }
  return 1;
}

=head2 C<make_body_field( $record )>

This class method makes a type safe method to get/set the named field
of the xPL Message body.

For instance, called as:

  __PACKAGE__->make_body_field({
                                name => 'interval',
                                validation => { type => 'IntegerRange',
                                                min => 5, max => 30 ),
                                error => 'It should be blah, blah, blah.',
                               );

it creates a method that can be called as:

  $msg->interval(5);

or:

  my $interval = $msg->interval();

=cut

sub make_body_field {
  my $pkg = shift;
  my $rec = shift or $pkg->argh('BUG: missing body field record');
  my $name = $rec->{name} or
    $pkg->argh('BUG: missing body field record missing name');
  my $validation = $rec->{validation} || { type => 'Any' };
  $validation = xPL::Validation->new(%{$validation});
  my $die = $rec->{die} || 0;
  my $error_message =
    exists $rec->{error} ? $rec->{error} : $validation->error();

  my $error_handler = $die ? 'argh_named' : 'ouch_named';
  my $new = $pkg.$DOUBLE_COLON.$name;
  return if (defined &{$new});
#  print STDERR "  $new => body_field, ",$validation->summary,"\n";
  no strict qw/refs/;
  *{$new} =
    sub {
      $_[0]->_parse_body() if ($_[0]->{_body_content});
      if (@_ > 1) {
        if ($_[0]->{_strict} && !$validation->valid($_[1])) {
          $_[0]->$error_handler($name,
                                $name.$COMMA.$SPACE.$_[1].", is invalid.\n".
                                $error_message);
        }
        $_[0]->{_body}->{$name} = $_[1];
      }
      return $_[0]->{_body}->{$name};
    };
  use strict qw/refs/;
  return 1;
}

1;
__END__

=head1 TODO

There are some 'todo' items for this module:

=over 4

=item Support for additional developer fields in the header of xPL messages.

=back

=head2 EXPORT

None by default.

=head1 SEE ALSO

Project website: http://www.xpl-perl.org.uk/

=head1 AUTHOR

Mark Hindess, E<lt>soft-xpl-perl@temporalanomaly.comE<gt>

=head1 COPYRIGHT

Copyright (C) 2005, 2009 by Mark Hindess

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.7 or,
at your option, any later version of Perl 5 you may have available.

=cut