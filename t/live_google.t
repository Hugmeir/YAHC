#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use YAHC qw/yahc_conn_last_error yahc_conn_errors/;

unless ($ENV{TEST_LIVE}) {
    plan skip_all => "Enable live testing by setting env: TEST_LIVE=1";
}

if($ENV{http_proxy}) {
    plan skip_all => "http_proxy is set. We cannot test when proxy is required to visit google.com";
}

my ($yahc, $yahc_storage) = YAHC->new();
my %args = (
    host => "google.com",
    port => "80",
    method => "GET",
);

subtest "with 1ms timeout limit, expect an exception." => sub {
    lives_ok {
        my $c= $yahc->request({ %args, connect_timeout => 0.001 });
        $yahc->run;

        ok yahc_conn_last_error($c);
        my @found_error = grep {
           $_->[0] == YAHC::Error::CONNECT_TIMEOUT()
        } @{ yahc_conn_errors($c) };
        ok @found_error > 0;
    };
};

subtest "with 10s timeout limit, do not expect an exception." => sub {
    lives_ok {
        my $c = $yahc->request({ %args, connect_timeout => 10 });
        $yahc->run;
        ok !yahc_conn_last_error($c);
        diag substr($c->{response}{body}, 0, 80);
    } 'google.com send back something within 10s';
};

subtest "without timeout, do not expect an exception." => sub {
    lives_ok {
        my $c = $yahc->request({ %args });
        $yahc->run;
        ok !yahc_conn_last_error($c);
    } 'google.com send back something without timeout';
};

done_testing();
