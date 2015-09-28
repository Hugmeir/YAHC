package YAHC;

use strict;
use warnings;

our $VERSION = '0.018';

use EV;
use Time::HiRes;
use Exporter 'import';
use Scalar::Util qw/weaken/;
use Fcntl qw/F_GETFL F_SETFL O_NONBLOCK/;
use POSIX qw/EINPROGRESS EINTR EAGAIN EWOULDBLOCK strftime/;
use Socket qw/PF_INET SOCK_STREAM $CRLF SOL_SOCKET SO_ERROR inet_aton inet_ntoa pack_sockaddr_in/;
use constant SSL => $ENV{YAHC_NO_SSL} ? 0 : eval 'use IO::Socket::SSL 1.94 (); 1';
use constant SSL_WANT_READ  => SSL ? IO::Socket::SSL::SSL_WANT_READ()  : 0;
use constant SSL_WANT_WRITE => SSL ? IO::Socket::SSL::SSL_WANT_WRITE() : 0;

sub YAHC::Error::NO_ERROR                () { 0 }
sub YAHC::Error::REQUEST_TIMEOUT         () { 1 << 0 }
sub YAHC::Error::CONNECT_TIMEOUT         () { 1 << 1 }
sub YAHC::Error::DRAIN_TIMEOUT           () { 1 << 2 }

sub YAHC::Error::CONNECT_ERROR           () { 1 << 10 }
sub YAHC::Error::READ_ERROR              () { 1 << 11 }
sub YAHC::Error::WRITE_ERROR             () { 1 << 12 }
sub YAHC::Error::REQUEST_ERROR           () { 1 << 13 }
sub YAHC::Error::RESPONSE_ERROR          () { 1 << 14 }
sub YAHC::Error::CALLBACK_ERROR          () { 1 << 15 }
sub YAHC::Error::SSL_ERROR               () { 1 << 16 }
sub YAHC::Error::INTERNAL_ERROR          () { 1 << 31 }

sub YAHC::State::INITIALIZED             () { 0   }
sub YAHC::State::RESOLVE_DNS             () { 5   }
sub YAHC::State::WAIT_SYNACK             () { 10  }
sub YAHC::State::CONNECTED               () { 15  }
sub YAHC::State::SSL_HANDSHAKE           () { 20  }
sub YAHC::State::WRITING                 () { 25  }
sub YAHC::State::READING                 () { 30  }
sub YAHC::State::USER_ACTION             () { 35  }
sub YAHC::State::COMPLETED               () { 100 } # terminal state

use constant {
    # TCP_READ_CHUNK should *NOT* be lower than 16KB because of SSL things.
    # https://metacpan.org/pod/distribution/IO-Socket-SSL/lib/IO/Socket/SSL.pod
    # Another way might be if you try to sysread at least 16kByte all the time.
    # 16kByte is the maximum size of an SSL frame and because sysread returns
    # data from only a single SSL frame you can guarantee that there are no
    # pending data.
    TCP_READ_CHUNK              => 131072,
    CALLBACKS                   => [ qw/init_callback wait_synack_callback connected_callback
                                        writing_callback reading_callback callback/ ],
};

our @EXPORT_OK = qw/
    yahc_reinit_conn
    yahc_conn_last_error
    yahc_conn_id
    yahc_conn_url
    yahc_conn_target
    yahc_conn_state
    yahc_conn_errors
    yahc_conn_timeline
    yahc_conn_request
    yahc_conn_response
    yahc_conn_attempts_left
/;

our %EXPORT_TAGS = (all => \@EXPORT_OK);

################################################################################
# User facing functons
################################################################################

sub new {
    my ($class, $args) = @_;

    die 'YAHC: ->new() expect args to be a hashref' if defined $args and ref($args) ne 'HASH';
    die 'YAHC: please do `my ($yahc, $yahc_storage) = YAHC::new()` and keep both these objects in the same scope' unless wantarray;

    # wrapping target selection here allows all client share same list
    # and more importantly to share index within the list
    $args->{_target} = _wrap_target_selection($args->{host}) if $args->{host};

    my %storage;
    my $self = bless {
        loop                => new EV::Loop,
        pid                 => $$, # store pid to detect forks
        storage             => \%storage,
        last_connection_id  => $$ * 1000,
        debug               => delete $args->{debug} || $ENV{YAHC_DEBUG} || 0,
        keep_timeline       => delete $args->{keep_timeline} || $ENV{YAHC_TIMELINE} || 0,
        pool_args           => $args,
    }, $class;

    # this's a radical way of avoiding circular references.
    # let's see how it plays out in practise.
    weaken($self->{storage});
    weaken($self->{$_} = $storage{$_} = {}) for qw/watchers callbacks connections/;
    return $self, \%storage;
}

sub request {
    my ($self, @args) = @_;
    die 'YAHC: new_request() expects arguments' unless @args;
    die 'YAHC: storage object is destroyed' unless $self->{storage};

    my ($conn_id, $request) = (@args == 1 ? ('connection_' . $self->{last_connection_id}++, $args[0]) : @args);
    die "YAHC: Connection with name '$conn_id' already exists\n"
        if exists $self->{connections}{$conn_id};

    my $pool_args = $self->{pool_args};
    $request->{_target} = _wrap_target_selection($request->{host}) if $request->{host};
    do { $request->{$_} ||= $pool_args->{$_} if $pool_args->{$_} } foreach (qw/host port scheme request_timeout
                                                                               connect_timeout drain_timeout/);
    my $scheme = $request->{scheme} ||= 'http';
    die "YAHC: only support scheme http and https\n" unless $scheme eq 'http' || $scheme eq 'https';
    die "YAHC: host must be defined\n" unless $request->{host};

    my $conn = {
        id          => $conn_id,
        request     => $request,
        response    => { status => 0 },
        attempt     => 0,
        retries     => $request->{retries} || 0,
        state       => YAHC::State::INITIALIZED(),
        debug       => delete $request->{debug} || $self->{debug},
        keep_timeline => delete $request->{keep_timeline} || $self->{keep_timeline},
        selected_target => [],
    };

    my %callbacks;
    foreach (@{ CALLBACKS() }) {
        next unless exists $request->{$_};
        $callbacks{$_} = delete $request->{$_};
        $conn->{"has_$_"} = 1;
    }

    $self->{watchers}{$conn_id} = {};
    $self->{callbacks}{$conn_id} = \%callbacks;
    $self->{connections}{$conn_id} = $conn;

    return $conn if $request->{_test}; # for testing purposes
    $self->_set_init_state($conn_id);

    # if user fire new request in a callback we need to update stop_condition
    my $stop_condition = $self->{stop_condition};
    if ($stop_condition && $stop_condition->{all}) {
        $stop_condition->{connections}{$conn_id} = 1;
    }

    return $conn;
}

sub drop {
    my ($self, $c) = @_;
    my $conn_id = ref($c) eq 'HASH' ? $c->{id} : $c;
    my $conn = $self->{connections}{$conn_id}
      or return;

    _register_in_timeline($conn, "dropping connection from pool") if $conn->{keep_timeline};
    $self->_set_completed_state($conn_id) unless $conn->{state} == YAHC::State::COMPLETED();

    delete $self->{connections}{$conn_id};
    return $conn;
}

sub run         { shift->_run(0, @_)            }
sub run_once    { shift->_run(EV::RUN_ONCE)     }
sub run_tick    { shift->_run(EV::RUN_NOWAIT)   }
sub is_running  { !!shift->{loop}->depth        }
sub loop        { shift->{loop}                 }

################################################################################
# Routines to manipulate connections (also user facing)
################################################################################

sub yahc_reinit_conn {
    my ($conn, $args) = @_;
    die "YAHC: cannot reinit completed connection\n"
        if $conn->{state} >= YAHC::State::COMPLETED();

    $conn->{attempt} = 0;
    $conn->{state} = YAHC::State::INITIALIZED();
    return unless defined $args && ref($args) eq 'HASH';

    my $request = $conn->{request};
    do { $request->{$_} = $args->{$_} if $args->{$_} } foreach (keys %$args);
    $request->{_target} = _wrap_target_selection($args->{host}) if $args->{host};
}

sub yahc_conn_last_error {
    my $conn = shift;
    return unless $conn->{errors} && @{ $conn->{errors} };
    return wantarray ? @{ $conn->{errors}[-1] } : $conn->{errors}[-1];
}

sub yahc_conn_id            { $_[0]->{id}       }
sub yahc_conn_state         { $_[0]->{state}    }
sub yahc_conn_errors        { $_[0]->{errors}   }
sub yahc_conn_timeline      { $_[0]->{timeline} }
sub yahc_conn_request       { $_[0]->{request}  }
sub yahc_conn_response      { $_[0]->{response} }
sub yahc_conn_attempts_left { $_[0]->{retries} - $_[0]->{attempt} + 1 }

sub yahc_conn_target {
    my $target = $_[0]->{selected_target};
    return unless $target && scalar @{ $target };
    my ($host, $ip, $port) = @{ $target };
    return ($host || $ip) . ($port ne '80' && $port ne '443' ? ":$port" : '');
}

sub yahc_conn_url {
    my $target = $_[0]->{selected_target};
    my $request = $_[0]->{request};
    return unless $target && @{ $target };

    my ($host, $ip, $port, $scheme) = @{ $target };
    return "$scheme://"
           . ($host || $ip)
           . ($port ne '80' && $port ne '443' ? ":$port" : '')
           . ($request->{path} || "/")
           . (defined $request->{query_string} ? ("?" . $request->{query_string}) : "");
}

################################################################################
# Internals
################################################################################

sub _run {
    my ($self, $how, $until_state, @cs) = @_;
    die "YAHC: storage object is destroyed\n" unless $self->{storage};
    die "YAHC: reentering run\n" if $self->{loop}->depth;

    if ($self->{pid} != $$) {
        _log_message('YAHC: reinitializing event loop after forking') if $self->{debug};
        $self->{pid} = $$;
        $self->{loop}->loop_fork;
    }

    if (defined $until_state) {
        my $until_state_str = _strstate($until_state);
        die "YAHC: unknown until_state $until_state\n" if $until_state_str =~ m/unknown/;

        my $is_all = (@cs == 0);
        my @connections = $is_all ? values %{ $self->{connections} }
                                  : map { $self->{connections}{$_} || () }
                                    map { ref($_) eq 'HASH' ? $_->{id} : $_ } @cs;

        $self->{stop_condition} = {
            all             => $is_all,
            expected_state  => $until_state,
            connections     => { map { $_->{id} => 1 } grep { $_->{state} < $until_state } @connections },
        };
    } else {
        delete $self->{stop_condition};
    }

    my $loop = $self->{loop};
    $loop->now_update;

    if ($self->{debug}) {
        my $iterations = $loop->iteration;
        _log_message('YAHC: pid %d entering event loop%s', $$, ($until_state ? " with until state " . _strstate($until_state) : ''));
        $loop->run($how || 0);
        _log_message('YAHC: pid %d exited from event loop after %d iterations', $$, $loop->iteration - $iterations);
    } else {
        $loop->run($how || 0);
    }
}

sub _break {
    my ($self, $reason) = @_;
    _log_message('YAHC: pid %d breaking event loop because %s', $$, ($reason || 'no reason')) if $self->{debug};
    $self->{loop}->break(EV::BREAK_ONE)
}

sub _check_stop_condition {
    my ($self, $conn) = @_;
    my $stop_condition = $self->{stop_condition};
    return if !$stop_condition || $conn->{state} < $stop_condition->{expected_state};

    delete $stop_condition->{connections}{$conn->{id}};
    my $awaiting_connections = scalar keys %{ $stop_condition->{connections} };
    my $expected_state = $stop_condition->{expected_state};

    if ($awaiting_connections == 0) {
        $self->_break(sprintf("until state '%s' is reached", _strstate($expected_state)));
        return 1;
    }

    _log_message("YAHC: still have %d connections awaiting state '%s'",
                 $awaiting_connections, _strstate($expected_state)) if $self->{debug};
}

################################################################################
# IO routines
################################################################################

sub _set_init_state {
    my ($self, $conn_id) = @_;

    my $conn = $self->{connections}{$conn_id}  or die "YAHC: unknown connection id $conn_id\n";
    my $watchers = $self->{watchers}{$conn_id} or die "YAHC: no watchers for connection id $conn_id\n";

    $conn->{response} = { status => 0 };
    $conn->{state} = YAHC::State::INITIALIZED();
    _register_in_timeline($conn, "new state %s", _strstate($conn->{state})) if $conn->{keep_timeline};
    $self->_call_state_callback($conn, 'init_callback') if exists $conn->{has_init_callback};

    my $continue = 1;
    while ($continue) {
        delete $watchers->{io}; # implicit stop
        my $fh = delete $watchers->{_fh};
        $fh && close($fh), undef $fh;

        my $attempt = $conn->{attempt}++;
        if ($attempt > $conn->{retries}) {
            $self->_set_user_action_state($conn_id, YAHC::Error::CONNECT_ERROR(), "retries limit reached");
            return;
        }

        # If later I would need timeout covering multiple attempts
        # I can set them here under $attempt == 0 condition.
        # Also, in _set_until_state_timer I would go to USER_ACTION_STATE
        # instead of reinitializing connection.
        $self->_set_request_timer($conn_id)    if $conn->{request}{request_timeout};
        $self->_set_connection_timer($conn_id) if $conn->{request}{connect_timeout};
        $self->_set_drain_timer($conn_id)      if $conn->{request}{drain_timeout};

        eval {
            my ($host, $ip, $port, $scheme) = _get_next_target($conn);
            _register_in_timeline($conn, "Target $scheme://$host:$port ($ip:$port) chosen for attempt #$attempt") if $conn->{keep_timeline};

            my $sock = _build_socket_and_connect($ip, $port, $conn->{request});
            $self->_set_wait_synack_state($conn_id, $sock);
            $continue = 0;
            1;
        } or do {
            my $error = $@ || 'zombie error';
            _register_error($conn, YAHC::Error::CONNECT_ERROR(), "Connection attempt failed: $error");
        };
    }
}

sub _set_wait_synack_state {
    my ($self, $conn_id, $sock) = @_;

    my $conn = $self->{connections}{$conn_id}  or die "YAHC: unknown connection id $conn_id\n";
    my $watchers = $self->{watchers}{$conn_id} or die "YAHC: no watchers for connection id $conn_id\n";

    $conn->{state} = YAHC::State::WAIT_SYNACK();
    _register_in_timeline($conn, "new state %s", _strstate($conn->{state})) if $conn->{keep_timeline};
    $self->_call_state_callback($conn, 'wait_synack_callback') if exists $conn->{has_wait_synack_callback};

    my $wait_synack_cb = $self->_get_safe_wrapper($conn, sub {
        my $sockopt = getsockopt($sock, SOL_SOCKET, SO_ERROR);
        if (!$sockopt) {
            _register_error($conn, YAHC::Error::CONNECT_ERROR(), "Failed to do getsockopt(): $!");
            $self->_set_init_state($conn_id);
            return;
        }

        if (my $err = unpack("L", $sockopt)) {
            my $strerror = POSIX::strerror($err) || '<unknown POSIX error>';
            _register_error($conn, YAHC::Error::CONNECT_ERROR(), "Failed to connect: $strerror");
            $self->_set_init_state($conn_id);
            return;
        }

        $conn->{state} = YAHC::State::CONNECTED();
        _register_in_timeline($conn, "new state %s", _strstate($conn->{state})) if $conn->{keep_timeline};
        $self->_call_state_callback($conn, 'connected_callback') if exists $conn->{has_connected_callback};
        return if exists $self->{stop_condition} && $self->_check_stop_condition($conn);

        return $self->_set_ssl_handshake_state($conn_id) if $conn->{is_ssl};
        $self->_set_write_state($conn_id);
    });

    $watchers->{_fh} = $sock;
    $watchers->{io} = $self->{loop}->io($sock, EV::WRITE, $wait_synack_cb);
    $self->_check_stop_condition($conn) if exists $self->{stop_condition};
}

sub _set_ssl_handshake_state {
    my ($self, $conn_id) = @_;

    my $conn = $self->{connections}{$conn_id}  or die "YAHC: unknown connection id $conn_id\n";
    my $watchers = $self->{watchers}{$conn_id} or die "YAHC: no watchers for connection id $conn_id\n";

    $conn->{state} = YAHC::State::SSL_HANDSHAKE();
    _register_in_timeline($conn, "new state %s", _strstate($conn->{state})) if $conn->{keep_timeline};
    #$self->_call_state_callback($conn, 'writing_callback') if $conn->{has_writing_callback}; TODO

    my $fh = $watchers->{_fh};
    my $hostname = $conn->{selected_target}[0];

    my %options = (
        SSL_verifycn_name => $hostname,
        IO::Socket::SSL->can_client_sni ? ( SSL_hostname => $hostname ) : (),
        %{ $conn->{request}{ssl_options} || {} },
    );

    if ($conn->{keep_timeline}) {
        my $options_msg = join(', ', map { "$_=" . ($options{$_} || '') } keys %options);
        _register_in_timeline($conn, "start SSL handshake with options: $options_msg");
    }

    if (!IO::Socket::SSL->start_SSL($fh, %options, SSL_startHandshake => 0)) {
        _register_error($conn, YAHC::Error::SSL_ERROR(), "Failed to start SSL session: $IO::Socket::SSL::SSL_ERROR");
        return $self->_set_completed_state($conn_id);
    }

    my $handshake_cb = $self->_get_safe_wrapper($conn, sub {
        my $w = shift;
        if ($fh->connect_SSL) {
            _register_in_timeline($conn, "SSL handshake successfully completed") if $conn->{keep_timeline};
            return $self->_set_write_state($conn_id);
        }

        if ($! == EWOULDBLOCK) {
            return $w->events(EV::READ)  if $IO::Socket::SSL::SSL_ERROR == SSL_WANT_READ;
            return $w->events(EV::WRITE) if $IO::Socket::SSL::SSL_ERROR == SSL_WANT_WRITE;
        }

        _register_error($conn, YAHC::Error::SSL_ERROR(), "Failed to complete SSL handshake: <$!> SSL_ERROR: <$IO::Socket::SSL::SSL_ERROR>");
        $self->_set_init_state($conn_id);
    });

    my $watcher = $watchers->{io};
    $watcher->cb($handshake_cb);
    $watcher->events(EV::WRITE | EV::READ);
    $self->_check_stop_condition($conn) if $self->{stop_condition};
}

sub _set_write_state {
    my ($self, $conn_id) = @_;

    my $conn = $self->{connections}{$conn_id}  or die "YAHC: unknown connection id $conn_id\n";
    my $watchers = $self->{watchers}{$conn_id} or die "YAHC: no watchers for connection id $conn_id\n";

    $conn->{state} = YAHC::State::WRITING();
    _register_in_timeline($conn, "new state %s", _strstate($conn->{state})) if $conn->{keep_timeline};
    $self->_call_state_callback($conn, 'writing_callback') if exists $conn->{has_writing_callback};

    my $fh = $watchers->{_fh};
    my $buf = _build_http_message($conn);
    my $length = length($buf);

    _register_in_timeline($conn, "sending request of $length bytes") if $conn->{keep_timeline};

    my $write_cb = $self->_get_safe_wrapper($conn, sub {
        my $w = shift;
        my $wlen = syswrite($fh, $buf, $length);

        if (!defined $wlen) {
            if ($conn->{is_ssl}) {
                if ($! == EWOULDBLOCK) {
                    return $w->events(EV::READ)  if $IO::Socket::SSL::SSL_ERROR == SSL_WANT_READ;
                    return $w->events(EV::WRITE) if $IO::Socket::SSL::SSL_ERROR == SSL_WANT_WRITE;
                }

                _register_error($conn, YAHC::Error::WRITE_ERROR() | YAHC::Error::SSL_ERROR(),
                                "Failed to send HTTPS data: <$!> SSL_ERROR: <$IO::Socket::SSL::SSL_ERROR>");
                return $self->_set_init_state($conn_id);
            }

            return if $! == EWOULDBLOCK || $! == EINTR || $! == EAGAIN;
            _register_error($conn, YAHC::Error::WRITE_ERROR(), "Failed to send HTTP data: $!");
            $self->_set_init_state($conn_id);
        } elsif ($wlen == 0) {
            _register_error($conn, YAHC::Error::WRITE_ERROR(), "syswrite returned 0");
            $self->_set_init_state($conn_id);
        } else {
            substr($buf, 0, $wlen, '');
            $length -= $wlen;
            $self->_set_read_state($conn_id) if $length == 0;
        }
    });

    my $watcher = $watchers->{io};
    $watcher->cb($write_cb);
    $watcher->events(EV::WRITE);
    $self->_check_stop_condition($conn) if exists $self->{stop_condition};
}

sub _set_read_state {
    my ($self, $conn_id) = @_;

    my $conn = $self->{connections}{$conn_id}  or die "YAHC: unknown connection id $conn_id\n";
    my $watchers = $self->{watchers}{$conn_id} or die "YAHC: no watchers for connection id $conn_id\n";

    $conn->{state} = YAHC::State::READING();
    _register_in_timeline($conn, "new state %s", _strstate($conn->{state})) if $conn->{keep_timeline};
    $self->_call_state_callback($conn, 'reading_callback') if exists $conn->{has_reading_callback};

    my $buf = '';
    my $neck_pos = 0;
    my $decapitated = 0;
    my $content_length = 0;
    my $is_chunked = 0;
    my $fh = $watchers->{_fh};
    my $chunk_size = 0;
    my $body = ''; # used for chunked encoding

    my $read_cb = $self->_get_safe_wrapper($conn, sub {
        my $w = shift;
        my $rlen = sysread($fh, my $b = '', TCP_READ_CHUNK);
        if (!defined $rlen) {
            if ($conn->{is_ssl}) {
                if ($! == EWOULDBLOCK) {
                    return $w->events(EV::READ)  if $IO::Socket::SSL::SSL_ERROR == SSL_WANT_READ;
                    return $w->events(EV::WRITE) if $IO::Socket::SSL::SSL_ERROR == SSL_WANT_WRITE;
                }

                _register_error($conn, YAHC::Error::READ_ERROR() | YAHC::Error::SSL_ERROR(),
                                "Failed to receive HTTPS data: <$!> SSL_ERROR: <$IO::Socket::SSL::SSL_ERROR>");
                return $self->_set_init_state($conn_id);
            }

            return if $! == EWOULDBLOCK || $! == EINTR || $! == EAGAIN;
            _register_error($conn, YAHC::Error::READ_ERROR(), "Failed to receive HTTP data: $!");
            $self->_set_init_state($conn_id);
        } elsif ($rlen == 0) {
            if ($content_length > 0) {
                _register_error($conn, YAHC::Error::READ_ERROR(), "Premature EOF, expect %d bytes more", $content_length - length($buf));
            } else {
                _register_error($conn, YAHC::Error::READ_ERROR(), "Premature EOF");
            }
            $self->_set_init_state($conn_id);
        } else {
            $buf .= $b;
            if (!$decapitated && ($neck_pos = index($buf, "${CRLF}${CRLF}")) > 0) {
                my $headers = _parse_http_headers($conn, substr($buf, 0, $neck_pos, '')); # $headers are always defined but might be empty, maybe fix later
                $is_chunked = ($headers->{'Transfer-Encoding'} || '') eq 'chunked';

                if ($is_chunked && exists $headers->{'Trailer'}) {
                    $self->_set_user_action_state($conn_id, YAHC::Error::RESPONSE_ERROR(), "Chunked HTTP response with Trailer header");
                    return;
                } elsif (!$is_chunked && !exists $headers->{'Content-Length'}) {
                    $self->_set_user_action_state($conn_id, YAHC::Error::RESPONSE_ERROR(), "HTTP reponse without Content-Length");
                    return;
                }

                $decapitated = 1;
                $content_length = $headers->{'Content-Length'};
                substr($buf, 0, 4, ''); # 4 = length("$CRLF$CRLF")
                _register_in_timeline($conn, "headers parsed: content-length='%s' content-type='%s' transfer-encoding='%s'",
                                      $headers->{'Content-Length'}    || '<no-content-length>',
                                      $headers->{'Content-Type'}      || '<no-content-type>',
                                      $headers->{'Transfer-Encoding'} || '<no-transfer-encoding>') if $conn->{keep_timeline};
            }

            if ($decapitated && $is_chunked) {
                # in order to get the smallest chunk size we need
                # at least 4 bytes (2xCLRF), and there *MUST* be
                # last chunk which is at least 5 bytes (0\r\n\r\n)
                # so we can safely ignore $bufs that have less than 5 bytes
                while (length($buf) > ($chunk_size + 4)) {
                    my $neck_pos = index($buf, ${CRLF});
                    if ($neck_pos > 0) {
                        $chunk_size = hex(substr($buf, 0, $neck_pos));
                        if ($chunk_size == 0) { # end with, but as soon as we see 0\r\n\r\n we just mark it as done
                            $conn->{response}{body} = $body;
                            $self->_set_user_action_state($conn_id);
                            return;
                        } else {
                            if (length($buf) >= $chunk_size + $neck_pos + 2 + 2) {
                                $body .= substr($buf, $neck_pos + 2, $chunk_size);
                                substr($buf, 0, $neck_pos + 2 + $chunk_size + 2, '');
                                $chunk_size = 0;
                            } else {
                                last; # dont have enough data in this pass, wait for one more read
                            }
                        }
                    } else {
                        last if $neck_pos < 0 && $chunk_size == 0; # in case we couldnt get the chunk size in one go, we must concat until we have something
                        $self->_set_user_action_state($conn_id, YAHC::Error::RESPONSE_ERROR(), "error processing chunked data, couldnt find CLRF[index:$neck_pos] in buf");
                        return;
                    }
                }
            } elsif ($decapitated && length($buf) >= $content_length) {
                $conn->{response}{body} = (length($buf) > $content_length ? substr($buf, 0, $content_length) : $buf);
                $self->_set_user_action_state($conn_id);
            }
        }
    });

    my $watcher = $watchers->{io};
    $watcher->cb($read_cb);
    $watcher->events(EV::READ);
    $self->_check_stop_condition($conn) if exists $self->{stop_condition};
}

sub _set_user_action_state {
    my ($self, $conn_id, $error, $strerror) = @_;
    $error ||= YAHC::Error::NO_ERROR();
    $strerror ||= '<no strerror>';

    # this state may be used in critical places,
    # so it should *NEVER* throw exception
    my $conn = $self->{connections}{$conn_id}
      or warn "YAHC: try to _set_user_action_state() for unknown connection $conn_id",
        return;

    $conn->{state} = YAHC::State::USER_ACTION();
    _register_in_timeline($conn, "new state %s", _strstate($conn->{state})) if $conn->{keep_timeline};
    _register_error($conn, $error, $strerror) if $error;

    return $self->_set_completed_state($conn_id) unless exists $conn->{has_callback};
    my $cb = $self->{callbacks}{$conn_id}{callback};

    eval {
        _register_in_timeline($conn, "call callback%s", $error ? " error=$error, strerror='$strerror'" : '') if $conn->{keep_timeline};
        $cb->($conn, $error, $strerror);
        1;
    } or do {
        my $error = $@ || 'zombie error';
        _register_error($conn, YAHC::Error::CALLBACK_ERROR(), "Exception in user action callback (close connection): $error");
        warn "YAHC: exception in user action callback (close connection): $error";
        $self->{state} = YAHC::State::COMPLETED();
    };

    $self->{loop}->now_update;

    my $state = $conn->{state};
    _register_in_timeline($conn, "after invoking callback state is %s", _strstate($state)) if $conn->{keep_timeline};

    if ($state == YAHC::State::INITIALIZED()) {
        $self->_set_init_state($conn_id);
    } elsif ($state == YAHC::State::USER_ACTION() || $state == YAHC::State::COMPLETED()) {
        $self->_set_completed_state($conn_id);
    } else {
        _register_error($conn, YAHC::Error::CALLBACK_ERROR(), "callback set unsupported state");
        $self->_set_completed_state($conn_id);
    }
}

sub _set_completed_state {
    my ($self, $conn_id) = @_;

    # this's a terminal state,
    # so setting this state should *NEVER* fail
    delete $self->{callbacks}{$conn_id};
    my $watchers = delete $self->{watchers}{$conn_id};
    my $conn = $self->{connections}{$conn_id}
      or warn "YAHC: try to _set_completed_state() for unknown connection $conn_id",
        return;

    $conn->{state} = YAHC::State::COMPLETED();
    _register_in_timeline($conn, "new state %s", _strstate($conn->{state})) if $conn->{keep_timeline};

    my $fh = $watchers->{_fh};
    $fh && close($fh);
    undef $watchers; # implicit stop

    $self->_check_stop_condition($conn) if exists $self->{stop_condition};
}

sub _build_socket_and_connect {
    my ($ip, $port, $timeouts) = @_;

    my $sock;
    socket($sock, PF_INET, SOCK_STREAM, 0) or die "Failed to construct TCP socket: $!\n";

    my $flags = fcntl($sock, F_GETFL, 0) or die "Failed to get fcntl F_GETFL flag: $!\n";
    fcntl($sock, F_SETFL, $flags | O_NONBLOCK) or die "Failed to set fcntl O_NONBLOCK flag: $!\n";

    my $ip_addr = inet_aton($ip) or die "Invalid IP address";
    my $addr = pack_sockaddr_in($port, $ip_addr);
    if (!connect($sock, $addr) && $! != EINPROGRESS) {
        die "Failed to connect: $!\n";
    }

    return $sock;
}

sub _get_next_target {
    my $conn = shift;
    my ($host, $ip, $port, $scheme) = $conn->{request}{_target}->($conn);

    # TODO STATE_RESOLVE_DNS
    ($host, $port) = ($1, $2) if !$port && $host =~ m/^(.+):([0-9]+)$/o;
    $ip = $host if !$ip && $host =~ m/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/o;
    $ip ||= inet_ntoa(gethostbyname($host) or die "Failed to resolve '$host': $!\n");
    $scheme ||= $conn->{request}{scheme} || 'http';
    $port   ||= $conn->{request}{port} || ($scheme eq 'https' ? 443 : 80);

    $conn->{is_ssl} = $scheme eq 'https';
    return @{ $conn->{selected_target} = [ $host, $ip, $port, $scheme ] };
}

################################################################################
# Timers
################################################################################

sub _set_request_timer    { $_[0]->_set_until_state_timer($_[1], 'request_timeout', YAHC::State::USER_ACTION(), YAHC::Error::REQUEST_TIMEOUT()) }
sub _set_connection_timer { $_[0]->_set_until_state_timer($_[1], 'connect_timeout', YAHC::State::CONNECTED(),   YAHC::Error::CONNECT_TIMEOUT()) }
sub _set_drain_timer      { $_[0]->_set_until_state_timer($_[1], 'drain_timeout',   YAHC::State::READING(),     YAHC::Error::DRAIN_TIMEOUT())   }

sub _set_until_state_timer {
    my ($self, $conn_id, $timeout_name, $state, $error_to_report) = @_;

    my $timer_name = $timeout_name . '_timer';
    my $conn = $self->{connections}{$conn_id}  or die "YAHC: unknown connection id $conn_id\n";
    my $watchers = $self->{watchers}{$conn_id} or die "YAHC: no watchers for connection id $conn_id\n";

    delete $watchers->{$timer_name}; # implicit stop
    my $timeout = $conn->{request}{$timeout_name};
    return unless $timeout;

    my $timer_cb = sub { # there is nothing what can throw exception
        if ($conn->{state} < $state) {
            _register_error($conn, $error_to_report, "$timeout_name of %.3fs expired", $timeout);
            $self->_set_init_state($conn_id);
        } else {
            _register_in_timeline($conn, "delete $timer_name") if $conn->{keep_timeline};
        }
    };

    _register_in_timeline($conn, "setting $timeout_name to %.3fs", $timeout) if $conn->{keep_timeline};

    $self->{loop}->now_update;
    my $w = $watchers->{$timer_name} = $self->{loop}->timer_ns($timeout, 0, $timer_cb);
    $w->priority(-2); # set lowest priority
    $w->start;
}

################################################################################
# HTTP functions
################################################################################

# copy-paste from Hijk
sub _build_http_message {
    my $conn = shift;
    my $request = $conn->{request};
    my $path_and_qs = ($request->{path} || "/") . (defined $request->{query_string} ? ("?" . $request->{query_string}) : "");

    return join(
        $CRLF,
        ($request->{method} || "GET") . " $path_and_qs " . ($request->{protocol} || "HTTP/1.1"),
        "Host: " . $conn->{selected_target}[0],
        defined($request->{body}) ? ("Content-Length: " . length($request->{body})) : (),
        $request->{head} ? (
            map {
                $request->{head}[2*$_] . ": " . $request->{head}[2*$_+1]
            } 0..$#{$request->{head}}/2
        ) : (),
        "",
        defined($request->{body}) ? $request->{body} : ""
    );
}

sub _parse_http_headers {
    my $conn = shift;
    my $proto       = substr($_[0], 0, 8);
    my $status_code = substr($_[0], 9, 3);
    substr($_[0], 0, index($_[0], $CRLF) + 2, ''); # 2 = length($CRLF)

    my %headers;
    for (split /${CRLF}/o, $_[0]) {
        my ($key, $value) = split(/: /, $_, 2);
        $headers{$key} = $value;
    }

    $conn->{response} = {
        proto  => $proto,
        status => $status_code,
        head   => \%headers,
    };

    return \%headers;
}

################################################################################
# Helpers
################################################################################

sub _wrap_target_selection {
    my $host = shift;
    my $ref = ref($host);

    return sub { $host } if $ref eq '';
    return $host         if $ref eq 'CODE';

    my $idx = 0;
    return sub { $host->[$idx++ % @$host]; } if $ref eq 'ARRAY';
    die "YAHC: unsupported host format\n";
}

sub _call_state_callback {
    my ($self, $conn, $cb_name) = @_;
    my $cb = $self->{callbacks}{$conn->{id}}{$cb_name};
    return unless $cb;

    eval {
        $cb->($conn);
        1;
    } or do {
        my $error = $@ || 'zombie error';
        _register_error($conn, YAHC::Error::CALLBACK_ERROR(), "Exception in state callback (ignore error): $error");
        warn "YAHC: exception in state callback (ignore error): $error";
    };

    # $self->{loop}->now_update; # XXX expect state callbacks to be small
}

sub _get_safe_wrapper {
    my ($self, $conn, $sub) = @_;
    return sub { eval {
        $sub->(@_);
        1;
    } or do {
        my $error = $@ || 'zombie error';
        _register_error($conn, YAHC::Error::INTERNAL_ERROR(), "Exception callback: $error");
        warn "YAHC: exception in callback: $error";
        $self->_set_completed_state($conn->{id});
    }};
}

sub _register_in_timeline {
    my ($conn, $format, @arguments) = @_;
    my $event = sprintf("$format", @arguments);
    _log_message("YAHC connection '%s': %s", $conn->{id}, $event) if $conn->{debug};
    push @{ $conn->{timeline} ||= [] }, [ $event, $conn->{state}, Time::HiRes::time ] if $conn->{keep_timeline};
}

sub _register_error {
    my ($conn, $error, $format, @arguments) = @_;
    my $strerror = sprintf("$format", @arguments);
    _register_in_timeline($conn, "error=$strerror ($error)") if $conn->{keep_timeline};
    push @{ $conn->{errors} ||= [] }, [ $error, $strerror, [ @{ $conn->{selected_target} } ], Time::HiRes::time ];
}

sub _strstate {
    my $state = shift;
    return 'STATE_INIT'         if $state eq YAHC::State::INITIALIZED();
    return 'STATE_RESOLVE_DNS'  if $state eq YAHC::State::RESOLVE_DNS();
    return 'STATE_WAIT_SYNACK'  if $state eq YAHC::State::WAIT_SYNACK();
    return 'STATE_CONNECTED'    if $state eq YAHC::State::CONNECTED();
    return 'STATE_WRITING'      if $state eq YAHC::State::WRITING();
    return 'STATE_READING'      if $state eq YAHC::State::READING();
    return 'STATE_SSL_HANDSHAKE'if $state eq YAHC::State::SSL_HANDSHAKE();
    return 'STATE_USER_ACTION'  if $state eq YAHC::State::USER_ACTION();
    return 'STATE_COMPLETED'    if $state eq YAHC::State::COMPLETED();
    return "<unknown state $state>";
}

sub _log_message {
    my $format = shift;
    my $now = Time::HiRes::time;
    my ($sec, $ms) = split(/[.]/, $now);
    printf STDERR "[%s.%-5d] [$$] $format\n", POSIX::strftime('%F %T', localtime($now)), $ms || 0, @_;
}

1;

__END__

=encoding utf8

=head1 NAME

YAHC - Yet another HTTP client

=head1 SYNOPSIS

    use YAHC qw/yahc_reinit_conn/;

    my @hosts = ('www.booking.com', 'www.google.com:80');
    my ($yahc, $yahc_storage) = YAHC->new({ host => \@hosts });

    $yahc->request({ path => '/', host => 'www.reddit.com' });
    $yahc->request({ path => '/', host => sub { 'www.reddit.com' } });
    $yahc->request({ path => '/', host => \@hosts });
    $yahc->request({ path => '/', callback => sub { ... } });
    $yahc->request({ path => '/' });
    $yahc->request({
        path => '/',
        callback => sub {
            yahc_reinit_conn($_[0], { host => 'www.newtarget.com' })
                if $_[0]->{response}{status} == 301;
        }
    });

    $yahc->run;

=head1 DESCRIPTION

YAHC is fast & minimal low-level asynchronous HTTP client intended to be used
where you control both the client and the server. Is especially suits cases
where set of requests need to be executed against group of machines.

It is C<NOT> a general HTTP user agent, it doesn't support redirects,
proxies and any number of other advanced HTTP features like (in
roughly descending order of feature completeness) L<LWP::UserAgent>,
L<WWW::Curl>, L<HTTP::Tiny>, L<HTTP::Lite> or L<Furl>. This library is
basically one step above manually talking HTTP over sockets.

YAHC supports SSL.

=head1 STATE MACHINE

Each YAHC connection goes through following list of states in its lifetime:

                  +-----------------+
              +<<-|   INITALIZED    <-<<+
              v   +-----------------+   ^
              v           |             ^
              v   +-------v---------+   ^
              +<<-+   RESOLVE DNS   +->>+
              v   +-----------------+   ^
              v           |             ^
              v   +-------v---------+   ^
              +<<-+   WAIT SYNACK   +->>+
              v   +-----------------+   ^
              v           |             ^
     Path in  v   +-------v---------+   ^  Retry
     case of  +<<-+    CONNECTED    +->>+  logic
     failure  v   +-----------------+   ^  path
              v           |             ^
              v   +-------v---------+   ^
              +<<-+     WRITING     +->>+
              v   +-----------------+   ^
              v           |             ^
              v   +-------v---------+   ^
              +<<-+     READING     +->>+
              v   +-----------------+   ^
              v           |             ^
              v   +-------v---------+   ^
              +>>->   USER ACTION   +->>+
                  +-----------------+
                          |
                  +-------v---------+
                  |    COMPLETED    |
                  +-----------------+


There are three main paths:

=over 4

=item 1) Normal execution (central line).

    In normal situation a connection after being initialized goes through state:
    - RESOLVE DNS
    - WAIT SYNACK - wait finishing of handshake
    - CONNECTED
    - WRITTING - sending request body
    - READING - awaiting and reading response
    - USER ACTION - see below
    - COMPLETED - all done, this is terminal state

    * SSL connection has extra state SSL_HANDSHAKE after CONNECTED state.
    * State 'RESOLVE DNS' is not implemented yet.

=item 2) Retry path (right line).

    In case of IO error during normal execution YAHC retries connection
    C<retries> times. In practise this means that connection goes back to
    INITIALIZED state.

    * It's possible for a connection to go directly to COMPLETED state in case of internal error.

=item 3) Failure path (left line).

    If all retry attempts did not succeeded a connection goes to state 'USER ACTION' (see below).

=back

=head1 State 'USER ACTION'

=head1 METHODS

=head2 new

This method creates YAHC object and accompanying storage object:

    my ($yahc, $yahc_storage) = YAHC->new();

This's a radical way of solving all possible memleak because of cyclic
references in callbacks. Since all references of callbacks are kept in
$yahc_storage object it's fine to use YAHC object inside request callback:

    my $yahc->request({
        callback => sub {
            $yahc->stop; # this is fine!!!
        },
    });

However, use has to garantee that both $yahc and $yahc_storage objects are kept
in the same namespace. So, they will be destroyed at the same time.

This method can be passed with all parameters supported by C<request>. They
will be inhereted by all requests.

=head2 request

    protocol               => "HTTP/1.1", # (or "HTTP/1.0")
    scheme                 => "http" or "https"
    host                   => see below,
    port                   => ...,
    method                 => "GET",
    path                   => "/",
    query_string           => "",
    head                   => [],
    body                   => "",

    # timeouts
    connect_timeout        => undef,
    request_timeout        => undef,
    drain_timeout          => undef,

    # callbacks
    init_callback          => undef,
    wait_synack_callback   => undef,
    connected_callback     => undef,
    writing_callback       => undef,
    reading_callback       => undef,
    callback               => undef,

Notice how YAHC does not take a full URI string as input, you have to
specify the individual parts of the URL. Users who need to parse an
existing URI string to produce a request should use the L<URI> module
to do so.

For example, to send a request to C<http://example.com/flower?color=red>, pass
the following parameters:

    $yach->request({
        host         => "example.com",
        port         => "80",
        path         => "/flower",
        query_string => "color=red"
    });

YAHC doesn't escape any values for you, it just passes them through
as-is. You can easily produce invalid requests if e.g. any of these
strings contain a newline, or aren't otherwise properly escaped.

Notice that you do not need to put the leading C<"?"> character in the
C<query_string>. You do, however, need to properly C<uri_escape> the content of
C<query_string>.

The value of C<head> is an C<ArrayRef> of key-value pairs instead of a
C<HashRef>, this way you can decide in which order the headers are
sent, and you can send the same header name multiple times. For
example:

    head => [
        "Content-Type" => "application/json",
        "X-Requested-With" => "YAHC",
    ]

Will produce these request headers:

    Content-Type: application/json
    X-Requested-With: YAHC

The value of C<connect_timeout>, C<request_timeout> and C<drain_timeout> is in
floating point seconds, and is used as the time limit for connecting to the
host (reaching CONNECTED state), full request time (reaching COMPLETED state)
and sending request to remote site (reaching READING state) respectively. The
default value for all is C<undef>, meaning no timeout limit. If you don't
supply these timeouts and the host really is unreachable or slow, we'll reach
the TCP timeout limit before returning some other error to you.

The value of C<init_callback>, C<wait_synack_callback>, C<connected_callback>,
C<writing_callback>, C<reading_callback> is CodeRef to a subroutine which is
called upon reaching corresponding state. Any exception thrown in the
subroutine moves connection to COMPLETED state effectivly terminating any
ongoing IO.

The value of C<callback> defines main request callback.
TODO

We currently don't support servers returning a http body without an accompanying
C<Content-Length> header; bodies B<MUST> have a C<Content-Length> or we won't pick
them up.

=head2 drop

Given connection HashRef or conn_id move connection to COMPLETED state (avoiding
'USER ACTION' state) and drop it from internal pool.

=head2 run

Start YAHC's loop. The loop stops when all connection complete.

Note that C<run> can accept two extra parameters: until_state and
list of connections. These two parameters tell YAHC to break the loop once
specified connections reach desired state.

For example:

    $yahc->run(YAHC::State::READING(), $conn_id);

Will loop until connection '$conn_id' move to state READING meaning that the
data has been sent to remote side. In order to gather response one should later
call:

    $yahc->run(YAHC::State::COMPLETED(), $conn_id);

Leaving list of connection empty makes YAHC waiting for all connection reaching
needed until_state.

Note that waiting one particular connection to finish doesn't mean that others
are not executed. Instead, all active connections are looped at the same
time, but YAHC breaks the loop once waited connection reaches needed state.

=head2 run_once

Same as run but with EV::RUN_ONCE set. For more details check L<https://metacpan.org/pod/EV>

=head2 run_tick

Same as run but with EV::RUN_NOWAIT set. For more details check L<https://metacpan.org/pod/EV>

=head2 is_running

Return true if YAHC is running, false otherwise.

=head2 loop

Return underlying EV loop object.

=head1 EXPORTED FUNCTIONS

=head2 yahc_reinit_conn

TODO

=head2 yahc_conn_id

Return id of given connection.

=head2 yahc_conn_state

Retrun state of given connection

=head2 yahc_conn_target

Return selected host and port for current attempt for given connection.
Format "host:port". Default port values are omited.

=head2 yahc_conn_url

Same as C<yahc_conn_target> but return full URL

=head2 yahc_conn_errors
=head2 yahc_conn_last_error

TODO

=head2 yahc_conn_timeline

Return timeline of given connection. See more about timeline in description of
C<new> method.

=head2 yahc_conn_request

Return request of given connection. See C<request>.

=head2 yahc_conn_response

Return response of given connection. See C<request>.

=head1 REPOSITORY

L<https://github.com/ikruglov/YAHC>

=head1 AUTHORS

Ivan Kruglov <ivan.kruglov@yahoo.com>

=head1 COPYRIGHT

Copyright (c) 2013 Ivan Kruglov C<< <ivan.kruglov@yahoo.com> >>.

=head1 ACKNOWLEDGMENT

This module derived lots of ideas, code and docs from Hijk
L<https://github.com/gugod/Hijk>. This module was originally developed for
Booking.com.

=head1 LICENCE

The MIT License

=head1 DISCLAIMER OF WARRANTY

BECAUSE THIS SOFTWARE IS LICENSED FREE OF CHARGE, THERE IS NO WARRANTY
FOR THE SOFTWARE, TO THE EXTENT PERMITTED BY APPLICABLE LAW. EXCEPT WHEN
OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES
PROVIDE THE SOFTWARE "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER
EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE
ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE SOFTWARE IS WITH
YOU. SHOULD THE SOFTWARE PROVE DEFECTIVE, YOU ASSUME THE COST OF ALL
NECESSARY SERVICING, REPAIR, OR CORRECTION.

IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING
WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MAY MODIFY AND/OR
REDISTRIBUTE THE SOFTWARE AS PERMITTED BY THE ABOVE LICENCE, BE
LIABLE TO YOU FOR DAMAGES, INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL,
OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OR INABILITY TO USE
THE SOFTWARE (INCLUDING BUT NOT LIMITED TO LOSS OF DATA OR DATA BEING
RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD PARTIES OR A
FAILURE OF THE SOFTWARE TO OPERATE WITH ANY OTHER SOFTWARE), EVEN IF
SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF
SUCH DAMAGES.

=cut
