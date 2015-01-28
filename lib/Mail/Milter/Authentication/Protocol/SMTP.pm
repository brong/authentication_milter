package Mail::Milter::Authentication::Protocol::SMTP;
use strict;
use warnings;
our $VERSION = 0.6;

use English qw{ -no_match_vars };
use Email::Date::Format qw{ email_date };
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTP ();
use Email::Simple;
use Digest::MD5 qw{ md5_base64 };
use Net::IP;

use Mail::Milter::Authentication::Constants qw{ :all };

sub protocol_process_request {
    my ( $self ) = @_;

    $self->{'smtp'} = {
        'fwd_helo_host' => q{},
        'helo_host'     => q{},
        'has_connected' => 0,
        'has_data'      => 0,
        'connect_ip'    => $self->{'server'}->{'peeraddr'},
        'connect_host'  => $self->{'server'}->{'peeraddr'}, ## TODO Lookup Name Here
        'last_command'  => 0,
        'headers'       => [],
        'body'          => q{},
    };

    my $smtp = $self->{'smtp'};
    my $socket = $self->{'socket'};
    my $handler = $self->{'handler'}->{'_Handler'};

    $smtp->{'server_name'} = 'server.example.com';

    # Get connect host and Connect IP from the connection here!

    print $socket "220 " . $smtp->{'server_name'} . " ESMTP AuthenticationMilter\r\n";

    $handler->set_symbol( 'C', 'j', $smtp->{'server_name'} );
    $handler->set_symbol( 'C', '{rcpt_host}', $smtp->{'server_name'} );

    $smtp->{'queue_id'} = md5_base64( "Authentication Milter Client $PID " . time() );
    $handler->set_symbol( 'C', 'i', $smtp->{'queue_id'} );

    COMMAND:
    while ( ! $smtp->{'last_command'} ) {

        my $command = <$socket> || last COMMAND;
        $command =~ s/\r?\n$//;

        $self->logdebug( "receive command $command" );

        my $returncode = SMFIS_CONTINUE;

        if ( $command =~ /^EHLO/ ) {
            $self->smtp_command_ehlo( $command );
        }
        elsif ( $command =~ /^HELO/ ) {
            $self->smtp_command_helo( $command );
        }
        elsif ( $command =~ /^XFORWARD/ ) {
            $self->smtp_command_xforward( $command );
        }
        elsif ( $command =~ /^MAIL FROM:/ ) {
            $self->smtp_command_mailfrom( $command );
        }
        elsif ( $command =~ /^RCPT TO:/ ) {
            $self->smtp_command_rcptto( $command );
        }
        elsif ( $command =~ /^DATA/ ) {
            $self->smtp_command_data( $command );
        }
        elsif ( $command =~ /^QUIT/ ){
            print $socket "221 Bye\n";
            last COMMAND;
        }
        else {
            $self->logerror( "Unknown SMTP command: $command" );
            print $socket "502 I don't understand\r\n";
        }

    }

    delete $self->{'smtp'};
    return;
}

sub smtp_command_ehlo {
    my ( $self, $command ) = @_;
    my $smtp = $self->{'smtp'};
    my $socket = $self->{'socket'};
    my $handler = $self->{'handler'}->{'_Handler'};

    if ( $smtp->{'has_data'} ) {
        $self->logerror( "Out of Order SMTP command: $command" );
        print $socket "501 Out of Order\r\n";
        return;
    }
    $smtp->{'helo_host'} = substr( $command,5 );
    print $socket "250-" . $smtp->{'server_name'} . "\r\n";
    print $socket "250-XFORWARD NAME ADDR PROTO HELO\r\n";
    print $socket "250 8BITMIME\r\n";
    return;
}

sub smtp_command_helo {
    my ( $self, $command ) = @_;
    my $smtp = $self->{'smtp'};
    my $socket = $self->{'socket'};
    my $handler = $self->{'handler'}->{'_Handler'};

    if ( $smtp->{'has_data'} ) {
        $self->logerror( "Out of Order SMTP command: $command" );
        print $socket "501 Out of Order\r\n";
        return;
    }
    $smtp->{'helo_host'} = substr( $command,5 );
    print $socket "250 " . $smtp->{'server_name'} . " Hi " . $smtp->{'helo_host'} . "\r\n";
    return;
}

sub smtp_command_xforward {
    my ( $self, $command ) = @_;
    my $smtp = $self->{'smtp'};
    my $socket = $self->{'socket'};
    my $handler = $self->{'handler'}->{'_Handler'};

    if ( $smtp->{'has_data'} ) {
        $self->logerror( "Out of Order SMTP command: $command" );
        print $socket "503 Out of Order\r\n";
        return;
    }
    my $xdata = substr( $command,9 );
    foreach my $entry ( split( q{ }, $xdata ) ) {
        my ( $key, $value ) = split( '=', $entry, 2 );
        if ( $key eq 'NAME' ) {
            $smtp->{'connect_host'} = $value;
        }
        elsif ( $key eq 'ADDR' ) {
            $smtp->{'connect_ip'} = $value;
        }
        elsif ( $key eq 'HELO' ) {
            $smtp->{'fwd_helo_host'} = $value;
        }
        else {
            $self->logerror( "Unknown XForward Entry: $key=$value" );
            # NOP
            ### log it here though
        }
    }
    print $socket "250 Ok\r\n";
    return;
}

sub smtp_command_mailfrom {
    my ( $self, $command ) = @_;
    my $smtp = $self->{'smtp'};
    my $socket = $self->{'socket'};
    my $handler = $self->{'handler'}->{'_Handler'};

    my $returncode;
    if ( $smtp->{'has_data'} ) {
        $self->logerror( "Out of Order SMTP command: $command" );
        print $socket "503 Out of Order\r\n";
        return;
    }
    # Do connect callback here, because of XFORWARD
    if ( ! $smtp->{'has_connected'} ) {
        $returncode = $handler->top_connect_callback( $smtp->{'connect_host'}, Net::IP->new( $smtp->{'connect_ip'} ) );
        if ( $returncode == SMFIS_CONTINUE ) {
            if ( $smtp->{'fwd_helo_host'} ) {
                $returncode = $handler->top_helo_callback( $smtp->{'fwd_helo_host'} );
            }
            else {
                $returncode = $handler->top_helo_callback( $smtp->{'helo_host'} );
            }
            if ( $returncode == SMFIS_CONTINUE ) {
                $smtp->{'has_connected'} = 1;
                my $envfrom = substr( $command,11 );
                $smtp->{'mail_from'} = $envfrom;
                $returncode = $handler->top_envfrom_callback( $envfrom );
                if ( $returncode == SMFIS_CONTINUE ) {
                    print $socket "250 Ok\r\n";
                }
                else {
                    print $socket "451 That's not right\r\n";
                }
            }
            else { 
                print $socket "451 That's not right\r\n";
            }
        }
        else { 
            print $socket "451 That's not right\r\n";
        }
    } 
    else { 
        my $envfrom = substr( $command,11 );
        $returncode = $handler->top_envfrom_callback( $envfrom );
        if ( $returncode == SMFIS_CONTINUE ) {
            print $socket "250 Ok\r\n";
        }
        else {
            print $socket "451 That's not right\r\n";
        }
    }
    
    return;
}

sub smtp_command_rcptto {
    my ( $self, $command ) = @_;
    my $smtp = $self->{'smtp'};
    my $socket = $self->{'socket'};
    my $handler = $self->{'handler'}->{'_Handler'};

    if ( $smtp->{'has_data'} ) {
        $self->logerror( "Out of Order SMTP command: $command" );
        print $socket "503 Out of Order\r\n";
        return;
    }
    my $envrcpt = substr( $command,9 );
    $smtp->{'rcpt_to'} = $envrcpt;
    my $returncode = $handler->top_envrcpt_callback( $envrcpt );
    if ( $returncode == SMFIS_CONTINUE ) {
        print $socket "250 Ok\r\n";
    }
    else {
        print $socket "451 That's not right\r\n";
    }

    return;
}

sub smtp_command_data {
    my ( $self, $command ) = @_;
    my $smtp = $self->{'smtp'};
    my $socket = $self->{'socket'};
    my $handler = $self->{'handler'}->{'_Handler'};

    my $headers = q{};
    my $body    = q{};
    my $done    = 0;
    my $fail    = 0;
    my $returncode;

    if ( $smtp->{'has_data'} ) {
        $self->logerror( "Repeated SMTP DATA command: $command" );
        print $socket "503 One at a time please\r\n";
        return;
    }
    $smtp->{'has_data'} = 1;
    print $socket "354 Send body\r\n";

    HEADERS:
    while ( my $dataline = <$socket> ) {
        $dataline =~ s/\r?\n$//;
        # Don't forget to deal with encoded . in the message text
        if ( $dataline eq '.' ) {
            $done = 1;
            last HEADERS;
        }
        if ( $dataline eq q{} ) {
            last HEADERS;
        }
        $headers .= $dataline . "\r\n";
    }

    {
        my $message_object = Email::Simple->new( $headers );
        my $header_object = $message_object->header_obj();
        my @header_pairs = $header_object->header_pairs();
        while ( @header_pairs ) {
            my $key   = shift @header_pairs;
            my $value = shift @header_pairs;
            push @{ $smtp->{'headers'} } , {
                'key'   => $key,
                'value' => $value,
            };
            my $returncode = $handler->top_header_callback( $key, $value );
            if ( $returncode != SMFIS_CONTINUE ) {
                $fail = 1;
            }
        }
    }

    $returncode = $handler->top_eoh_callback();
    if ( $returncode != SMFIS_CONTINUE ) {
        $fail = 1;
    }

    if ( ! $done ) {
        DATA:
        while ( my $dataline = <$socket> ) {
            # Don't forget to deal with encoded . in the message text
            last DATA if $dataline =~  /\.\r\n/;
            $body .= $dataline;
        }
        $returncode = $handler->top_body_callback( $body );
        if ( $returncode != SMFIS_CONTINUE ) {
            $fail = 1;
        }
    }

    $returncode = $handler->top_eom_callback();
    if ( $returncode != SMFIS_CONTINUE ) {
        $fail = 1;
    }

    if ( ! $fail ) {

        $smtp->{'body'} = $body;

        if ( $self->smtp_forward_to_destination() ) {
            print $socket "250 Queued as " . $smtp->{'queue_id'} . "\r\n";
        }
        else {
            $self->logerror( "SMTP Mail Rejected" );
            print $socket "451 That's not right\r\n";
        }
    }
    else { 
        print $socket "451 That's not right\r\n";
    }

    return;
}

sub smtp_insert_received_header {
    my ( $self ) = @_;
    my $smtp = $self->{'smtp'};

    my $value = join ( q{},

        'from ',
        $smtp->{'helo_host'},
        ' (',
            $smtp->{'connect_host'}
        ,
        ' [',
            $smtp->{'connect_ip'},
        '])',
        "\r\n",

        '    by ',
        $smtp->{'server_name'},
        ' (Authentication Milter)',
        ' with ESMTP;',
        "\r\n",

        '    ',
        email_date(),

    );

    splice @{ $smtp->{'headers'} }, 0, 0, {
        'key'   => 'Received',
        'value' => $value,
    };
    return;
}

sub smtp_forward_to_destination {
    my ( $self ) = @_;

    my $smtp = $self->{'smtp'};

    $self->smtp_insert_received_header();

    eval {

        my $smtpserver = 'localhost';
        my $smtpport = '12346';

        ## TODO this DOESNT set MAIL FROM and RCPT TO properly

        my $transport = Email::Sender::Transport::SMTP->new({
            'host'          => $smtpserver,
            'port'          => $smtpport,
        });

        my $email = q{};

        foreach my $header ( @{ $smtp->{'headers'} } ) {
            my $key   = $header->{'key'};
            my $value = $header->{'value'};
            $email .= "$key: $value\r\n";
        }
        $email .= "\r\n";
        $email .= $smtp->{'body'};

        sendmail( $email, { transport => $transport } );

    };
    if ( my $error = $@ ) {
        $self->logerror( "Sendmail error: $error" );
        return 0;
    }
    return 1;
}

sub add_header {
    my ( $self, $header, $value ) = @_;
    my $smtp = $self->{'smtp'};
    push @{ $smtp->{'headers'} } , {
        'key'   => $header,
        'value' => $value,
    };
    return;
}

## TODO
# change and insert headers could be
# affected by previously changed/inserted/deleted headers
# need to have a test case for this

sub change_header {
    my ( $self, $header, $index, $value ) = @_;
    my $smtp = $self->{'smtp'};

    my $header_i = 0;
    my $search_i  = 0;
    my $result_i;

    HEADER:
    foreach my $header_v ( @{ $smtp->{'headers'} } ) {
        if ( $header_v->{'key'} eq $header ) {
            $search_i ++;
            if ( $search_i == $index ) {
                $result_i = $header_i;
                last HEADER;
            }
        }
        $header_i ++;
    }

    if ( $result_i ) {
        if ( $value eq q{} ) {
            splice @{ $smtp->{'headers'} }, $result_i, 1;
        }
        else {
            $smtp->{'headers'}->[ $result_i ]->{'value'} = $value;
            #untested
        }
    }

}

sub insert_header {
    my ( $self, $index, $key, $value ) = @_;
    my $smtp = $self->{'smtp'};
    splice @{ $smtp->{'headers'} }, $index - 1, 0, {
        'key'   => $key,
        'value' => $value,
    };
    return;
}

1;

__END__

=head1 NAME

Mail::Milter::Authentication::Protocol::SMTP - SMTP protocol specific methods

=head1 DESCRIPTION

A PERL implemtation of email authentication standards rolled up into a single easy to use milter.

=head1 SYNOPSIS

Subclass of Net::Server::PreFork for bringing up the main server process for authentication_milter.

Please see Net::Server docs for more detail of the server code.

=head1 METHODS

=over

=item I<protocol_process_command( $command, $buffer )>

Process the command from the SMTP protocol stream.

=item I<add_header( $header, $value )>

Add a header

=item I<change_header( $header, $index, $value )>

Change a header

=item I<insert_header( $index, $key, $value )>

Insert a header

=back

=head1 DEPENDENCIES

  English
  Digest::MD5
  Net::IP

=head1 AUTHORS

Marc Bradshaw E<lt>marc@marcbradshaw.netE<gt>

=head1 COPYRIGHT

Copyright 2015

This library is free software; you may redistribute it and/or
modify it under the same terms as Perl itself.

