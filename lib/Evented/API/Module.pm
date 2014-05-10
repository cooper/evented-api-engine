# Copyright (c) 2013 Mitchell Cooper
# Module represents an API module and provides an interface for managing one.
package Evented::API::Module;

use warnings;
use strict;
use 5.010;

use Evented::Object;
use parent 'Evented::Object';

our $VERSION = $Evented::API::Engine::VERSION;
our $events  = $Evented::Object::events;

sub new {
    my ($class, %opts) = @_;
    my $mod = bless \%opts, $class;
    
    # TODO: check for required options.
    
    # default initialize handler.
    $mod->register_callback(init => sub {
            my $init = $mod->package->can('init') or return;
            $init->(@_);
        },
        name     => 'api.engine.init',
        priority => 100
    );
    
    # default void handler.
    $mod->register_callback(void => sub {
            my $void = $mod->package->can('void') or return;
            $void->(@_);
        },
        name     => 'api.engine.void',
        priority => 100
    );
    
    return $mod;
}

sub name    { shift->{name}{full}   }
sub package { shift->{package}      }
sub api     { shift->{api}          }

sub _log {
    my $mod = shift;
    $mod->api->_log("[$$mod{name}{full}] @_");
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
    my ($mod, $key, $default_value) = @_;
    return $mod->{store}{$key} //= $default_value;
}

# adds the item to a list store.
# if the store doesn't exist, creates it.
sub list_store_add {
    my ($mod, $key, $value) = @_;
    push @{ $mod->{store}{$key} ||= [] }, $value;
}

# returns all the items in a list store.
# if the store doesn't exist, this is
# still safe and returns an empty list.
sub list_store_items {
    my ($mod, $key) = @_;
    return @{ $mod->{store}{$key} || [] };
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
    push @{ $mod->{managed_objects} ||= [] }, $eo;
}

# returns true if an object is being managed by this module.
sub managing_object {
    my ($mod, $eo) = @_;
    my @objects = @{ $mod->{managed_objects} ||= [] };
    foreach my $_eo (@objects) {
        return scalar @objects if $_eo == $eo;
    }
    return;
}

# remove object from management, deleting all events.
sub release_object {
    my ($mod, $eo, $dont_remove) = @_;
    foreach my $event_name (keys %{ $eo->{$events}                    }) {
    foreach my $priority   (keys %{ $eo->{$events}{$event_name}       }) {
    foreach my $cb         (@{ $eo->{$events}{$event_name}{$priority} }) {
        next unless $cb->{caller}[0] eq $mod->package;
        $eo->delete_callback($event_name, $cb->{name});
    }}}
    
    # don't waste time removing this if we're removing them all.
    unless ($dont_remove) {
        my $objects = $mod->{managed_objects};
        @$objects   = grep { $_ != $eo } @$objects;
    }
    
}

# delete all the events managed by this module.
sub _delete_managed_events {
    my $mod = shift;
    $mod->release_object($_, 1) foreach @{ $mod->{managed_objects} };
    $mod->{managed_objects} = [];
}

####################
### DEPENDENCIES ###
####################

# returns the modules that this depends on.
sub depends {
    # TODO: do.
}

# returns the module that depend on this.
sub dependents {
    my $mod = shift;
    $mod->api->{loaded}
}

1;
