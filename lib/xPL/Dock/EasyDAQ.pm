package xPL::Dock::EasyDAQ;

=head1 NAME

xPL::Dock::EasyDAQ - xPL::Dock plugin for an EasyDAQ relay module

=head1 SYNOPSIS

  use xPL::Dock qw/EasyDAQ/;
  my $xpl = xPL::Dock->new();
  $xpl->main_loop();

=head1 DESCRIPTION

This module creates an xPL client for a serial port-based device.  There
are several usage examples provided by the xPL Perl distribution.

=head1 METHODS

=cut

use 5.006;
use strict;
use warnings;

use English qw/-no_match_vars/;
use Pod::Usage;
use xPL::Dock::Serial;

our @ISA = qw(xPL::Dock::Serial);
our %EXPORT_TAGS = ( 'all' => [ qw() ] );
our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );
our @EXPORT = qw();
our $VERSION = qw/$Revision$/[1];

{ # shortcut to save typing
  package Msg;
  use base 'xPL::BinaryMessage';
  sub new {
    my ($pkg, $letter, $number, $desc) = @_;
    return $pkg->SUPER::new(raw => pack('aC', $letter, $number),
                            desc => $desc);
  }
  1;
}

=head2 C<getopts( )>

This method returns the L<Getopt::Long> option definition for the
plugin.

=cut

sub getopts {
  my $self = shift;
  $self->{_baud} = 9600;
  return (
          'easydaq-verbose|easydaqverbose+' => \$self->{_verbose},
          'easydaq-baud|easydaqbaud=i' => \$self->{_baud},
          'easydaq=s' => \$self->{_device},
         );
}

=head2 C<init(%params)>

=cut

sub init {
  my $self = shift;
  my $xpl = shift;
  my %p = @_;

  $self->required_field($xpl,
                        'device', 'The --easydaq parameter is required', 1);
  $self->SUPER::init($xpl,
                     ack_timeout => 0.05,
                     reader_callback => \&device_reader,
                     @_);

  # Add a callback to receive incoming xPL messages
  $xpl->add_xpl_callback(id => 'easydaq', callback => \&xpl_in,
                         arguments => $self,
                         filter =>
                         {
                          message_type => 'xpl-cmnd',
                          class => 'control',
                          class_type => 'basic',
                          type => 'output',
                         });
  $self->{_state} = 0;
  $self->write(Msg->new('B', 0, 'set all ports to outputs'));
  return $self;
}

=head2 C<xpl_in(%xpl_callback_parameters)>

This is the callback that processes incoming xPL messages.  It handles
the incoming x10.basic schema messages.

=cut

sub xpl_in {
  my %p = @_;
  my $msg = $p{message};
  my $peeraddr = $p{peeraddr};
  my $peerport = $p{peerport};
  my $self = $p{arguments};
  my $xpl = $self->xpl;

  if ($msg->device eq 'debug') {
    $self->write(Msg->new('A', 0, 'query status of outputs'));
  }
  return 1 unless ($msg->device =~ /^o(\d+)$/);
  my $num = $LAST_PAREN_MATCH;
  my $command = lc $msg->current;
  if ($command eq "high") {
    $self->{_state} |= 1<<($num-1);
    $self->write(Msg->new('C', $self->{_state}, "setting port $num high"));
  } elsif ($command eq "low") {
    $self->{_state} &= 0xf^(1<<($num-1));
    $self->write(Msg->new('C', $self->{_state}, "setting port $num low"));
  } elsif ($command eq "pulse") {
    $self->{_state} |= 1<<($num-1);
    $self->write(Msg->new('C', $self->{_state}, "setting port $num high"));
    $self->{_state} &= 0xf^(1<<($num-1));
    $self->write(Msg->new('C', $self->{_state}, "setting port $num low"));
  } else {
    warn "Unsupported setting: $command\n";
  }
  return 1;
}

=head2 C<device_reader()>

This is the callback that processes output from the RFXCOM transmitter.
It is responsible for reading the 'ACK' messages and sending out any
queued transmit messages.

=cut

sub device_reader {
  my ($self, $buf, $last) = @_;
  print 'received: ', unpack('H*', $buf), "\n";
  return '';
}

1;
__END__

=head1 EXPORT

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
