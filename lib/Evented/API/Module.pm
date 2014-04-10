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

####################
### DATA STORAGE ###
####################

# store a piece of data specific to this module.
sub store {
    my ($mod, $key, $value) = @_;
    $mod->{store}{$key} = $value;
}

# fetch a piece of data specific to this module.
sub retrieve {
    my ($mod, $key) = @_;
    return $mod->{store}{$key};
}

#######################
### MANAGED OBJECTS ###
#######################
#
# 4/7/2014: Here's how I plan for this to work:
# 
# my $eo = some_arbitrary_actual_evented_object();
# $mod->manage_object($eo);                 adds weak mod to @{ $mod->{managed_objects} }
# $eo->register_event(blah => sub {...});   does everything as normal w/ caller information
# on unload...                              for each object, delete all from module package
#

# add an evented object to our managed list.
sub manage_object {
    my ($mod, $eo) = @_;
    return if !bless $mod || !$mod->isa('Evented::Object');
    my $count = managing_object($eo);
    return $count if $count;
    push @{ $mod->{managed_objects} }, $eo;
}

# returns true if an object is being managed by this module.
sub managing_object {
    my ($mod, $eo) = @_;
    my @objects = @{ $mod->{managed_objects} };
    foreach my $_eo (@objects) {
        return scalar @objects if $_eo == $eo;
    }
    return;
}

# delete all the events managed by this object.
sub _delete_managed_events {
    my $mod = shift;
}

1;
