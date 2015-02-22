package Mail::Milter::Authentication::Handler::TrustedIP;
use strict;
use warnings;
use base 'Mail::Milter::Authentication::Handler';
our $VERSION = 0.8;

use Net::IP;
use Sys::Syslog qw{:standard :macros};

sub is_trusted_ip_address {
    my ( $self, $ip_obj ) = @_;
    my $config = $self->handler_config();
    return 0 if not exists( $config->{'trusted_ip_list'} );
    my $trusted = 0;
    foreach my $trusted_ip ( @{ $config->{'trusted_ip_list'} } ) {
        my $trusted_obj = Net::IP->new($trusted_ip);
        my $is_overlap = $ip_obj->overlaps($trusted_obj) || 0;
        if (
               $is_overlap == $IP_A_IN_B_OVERLAP
            || $is_overlap == $IP_B_IN_A_OVERLAP     # Should never happen
            || $is_overlap == $IP_PARTIAL_OVERLAP    # Should never happen
            || $is_overlap == $IP_IDENTICAL
          )
        {
            $trusted = 1;
        }
    }
    return $trusted;
}

sub connect_callback {
    my ( $self, $hostname, $ip ) = @_;
    $self->{'is_trusted_ip_address'} = 0;
    if ( $self->is_trusted_ip_address($ip) ) {
        $self->dbgout( 'TrustedIP', 'pass', LOG_DEBUG );
        $self->add_c_auth_header('x-trusted-ip=pass');
        $self->{'is_trusted_ip_address'} = 1;
    }
    return;
}

sub close_callback {
    my ( $self ) = @_;
    delete $self->{'is_trusted_ip_address'};
    return;
}

1;
