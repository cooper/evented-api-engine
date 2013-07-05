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
    $mod->register_callback(init => sub {
            my $init = $mod->{name}{package}->can('init') or return;
            $init->(@_);
        },
        name     => 'api.engine.init',
        priority => 100
    );
    
    # default void handler.
    $mod->register_callback(void => sub {
            my $void = $mod->{name}{package}->can('void') or return;
            $void->(@_);
        },
        name     => 'api.engine.void',
        priority => 100
    );
    
    return $mod;
}

1;
