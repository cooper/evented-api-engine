# Copyright (c) 2013 Mitchell Cooper
# Module represents an API module and provides an interface for managing one.
package Evented::API::Module;

use warnings;
use strict;
use 5.010;

use Evented::Object;
use parent 'Evented::Object';

use Scalar::Util qw(blessed weaken);

our $VERSION = $Evented::API::Engine::VERSION;
our $events  = $Evented::Object::events;

sub new {
    my ($class, %opts) = @_;
    my $mod = bless \%opts, $class;
    
    # TODO: check for required options.
    
    # check if init and void return true values.
    my $returnCheck = sub {
        my $fire = shift;
        my %returns = %{ $fire->{$Evented::Object::props}{return} };
        foreach my $cb_name (keys %returns) {
            next if $returns{$cb_name};
            $mod->_log("'$cb_name' returned a false value");
            $fire->stop;
        }
        return 1;
    };
    
    # default initialize handler.
    $mod->on(init => sub {
            my $init = $mod->package->can('init') or return 1;
            $init->(@_);
        },
        name     => 'api.engine.initSubroutine',
        priority => 100
    );
    $mod->on(init => $returnCheck,
        name     => 'api.engine.returnCheck',
        priority => -1000
    );
    
    # default void handler.
    $mod->on(void => sub {
            my $void = $mod->package->can('void') or return 1;
            $void->(@_);
        },
        name     => 'api.engine.voidSubroutine',
        priority => 100
    );
    $mod->on(void => $returnCheck,
        name     => 'api.engine.returnCheck',
        priority => -1000
    );
    
    # registered callback.
    Evented::Object::add_class_monitor($mod->{package}, $mod);
    $mod->on('monitor:register_callback' => sub {
        my ($event, $eo, $event_name, $cb) = @_;
        
        # permanent - ignore.
        if ($cb->{permanent}) {
            $mod->_log("Permanent event: $event_name ($$cb{name}) registered to ".(ref($eo) || $eo));
            return;
        }
        
        # hold weak reference.
        my $e = [ $eo, $event_name, $cb->{name} ];
        weaken($e->[0]);
        $mod->list_store_add('managed_events', $e);
        $mod->_log("Event: $event_name ($$cb{name}) registered to ".(ref($eo) || $eo));
        
    }, name => 'api.engine.eventTracker');
    
    # deleted all callbacks for an event.
    $mod->on('monitor:delete_event' => sub {
        my ($event, $eo, $event_name) = @_;
        $mod->_log("Event: $event_name (all callbacks) deleted from ".(ref($eo) || $eo));
        $mod->list_store_remove_matches('managed_events', sub {
            my $e = shift;
            return unless $eo         == $e->[0];
            return unless $event_name eq $e->[1];
            return 1;
        });
    });
    
    # deleted a specific callback.
    $mod->on('monitor:delete_callback' => sub {
        my ($event, $eo, $event_name, $cb_name) = @_;
        $mod->_log("Event: $event_name ($cb_name) deleted from ".(ref($eo) || $eo));
        $mod->list_store_remove_matches('managed_events', sub {
            my $e = shift;
            return unless $eo         == $e->[0];
            return unless $event_name eq $e->[1];
            return unless $cb_name    eq $e->[2];
            return 1;
        }, 1);
    });
    
    # unload handler for destroying events callbacks.
    $mod->on(unload => sub {
        my $done;
        foreach my $e ($mod->list_store_items('managed_events')) {
            my ($eo, $event_name, $name) = @$e;
            
            # this is a weak reference --
            # if undefined, it was disposed of.
            return unless $eo;
            
            # first one.
            if (!$done) {
                $mod->_log('Destroying managed event callbacks');
                $mod->api->{indent}++;
                $done = 1;
            }
            
            # delete this callback.
            $eo->delete_callback($event_name, $name);
            $mod->_log("Event: $event_name ($name) deleted from ".(ref($eo) || $eo));
            
        }
        $mod->api->{indent}-- if $done;
        return 1;
    }, name => 'api.engine.deleteEvents');
    
    return $mod;
}

sub name       { shift->{name}{full}            }
sub package    { shift->{package}               }
sub api        { shift->{api}                   }
sub submodules { @{ shift->{submodules} || [] } }

sub _log {
    my $mod = shift;
    $mod->api->_log("[$$mod{name}{full}] @_");
}

##################
### SUBMODULES ###
##################

sub load_submodule {
    my ($mod, $mod_name) = @_;
    $mod->_log("Loading submodule $mod_name");
    $mod->api->{indent}++;
    my $ret = $mod->api->load_module($mod_name, [ $mod->{dir} ], 1);
    $mod->api->{indent}--;
    
    # add to submodules list. hold weak reference to parent module.
    if ($ret) {
        push @{ $mod->{submodules} ||= [] }, $ret;
        weaken($ret->{parent} = $mod);
    }
    
    return $ret;
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

# remove a single item matching.
# $max = stop searching when removed this many (optional)
sub list_store_remove_matches {
    my ($mod, $key, $sub, $max) = @_;
    my @before  = @{ $mod->{store}{$key} or return };
    my ($removed, @after) = 0;
    while (my $item = shift @before) {
        
        # it matches. add the remaining.
        if ($sub->($item)) {
            last if $removed == $max;
            next;
        }
        
        # no match. add and continue.
        push @after, $item;
        
    }
    
    # add the rest, store.
    push @after, @before;
    $mod->{store}{$key} = \@after;
    
    return $removed;
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

## add an evented object to our managed list.
#sub manage_object {
#    my ($mod, $eo) = @_;
#    return if !blessed $mod || !$mod->isa('Evented::Object');
#    my $count = managing_object($eo);
#    return $count if $count;
#    push @{ $mod->{managed_objects} ||= [] }, $eo;
#}
#
## returns true if an object is being managed by this module.
#sub managing_object {
#    my ($mod, $eo) = @_;
#    my @objects = @{ $mod->{managed_objects} ||= [] };
#    foreach my $_eo (@objects) {
#        return scalar @objects if $_eo == $eo;
#    }
#    return;
#}
#
## remove object from management, deleting all events.
#sub release_object {
#    my ($mod, $eo, $dont_remove) = @_;
#    foreach my $event_name (keys %{ $eo->{$events}                    }) {
#    foreach my $priority   (keys %{ $eo->{$events}{$event_name}       }) {
#    foreach my $cb         (@{ $eo->{$events}{$event_name}{$priority} }) {
#        next unless $cb->{caller}[0] eq $mod->package;
#        my $obtype = blessed $eo;
#        $mod->_log("Object release: $obtype.$event_name: $$cb{name}");
#        $eo->delete_callback($event_name, $cb->{name});
#    }}}
#    
#    # don't waste time removing this if we're removing them all.
#    unless ($dont_remove) {
#        my $objects = $mod->{managed_objects};
#        @$objects   = grep { $_ != $eo } @$objects;
#    }
#    
#}
#
## delete all the events managed by this module.
#sub _delete_managed_events {
#    my $mod = shift;
#    my $objects = $mod->{managed_objects} or return;
#    
#    $mod->_log("Releasing managed evented objects");
#    $mod->api->{indent}++;
#    
#    $mod->release_object($_, 1) foreach @$objects;
#    
#    @$objects = ();
#    $mod->api->{indent}--;
#}

# 5/14/2014: REVISION:
# 
# $mod->manage_object() is annoying. I have come up with a better idea.
# I designed Evented::Object class monitors for this purpose. See documentation.
# Briefly, it allows API engine to track the events added from the module package.
#

####################
### DEPENDENCIES ###
####################

# returns the modules that this depends on.
sub dependencies {
    return @{ shift->{dependencies} || [] };
}

# returns the module that depend on this.
sub dependents {
    my $mod = shift;
    my @mods;
    foreach my $m (@{ $mod->api->{loaded} }) {
        foreach my $dep ($m->dependencies) {
            next unless $dep == $mod;
            push @mods, $m;
            last;
        }
    }
    return @mods;
}

1;
