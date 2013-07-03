# Copyright (c) 2013 Mitchell Cooper
# Module represents an API module and provides an interface for managing one.
package Evented::API::Module;

use warnings;
use strict;
use 5.010;

use Evented::Object;
use parent 'Evented::Object';

our $VERSION = $Evented::API::Engine::VERSION;

sub new {
    my ($class, %opts) = @_;
    my $mod = bless \%opts, $class;
    
    # TODO: check for required options.
    
    # default initialize handler.
    $mod->register_event(initialize => sub {
            my $init = $mod->{name}{package}->can('init') or return;
            $init->(@_);
        },
        name     => 'default.initialize',
        priority => 100
    );
    
    return $mod;
}

1;
