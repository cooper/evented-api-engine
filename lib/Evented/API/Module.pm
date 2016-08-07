# Copyright (c) 2013 Mitchell Cooper
# Module represents an API module and provides an interface for managing one.
package Evented::API::Module;

use warnings;
use strict;
use 5.010;

use Evented::Object;
use parent 'Evented::Object';

use Scalar::Util qw(blessed weaken);

our $VERSION = Evented::API::Engine->VERSION;
our $events  = $Evented::Object::events;

sub new {
    my ($class, %opts) = @_;
    my $mod = bless \%opts, $class;

    # TODO: check for required options.


    # default initialize handler.
    $mod->register_callback(init => sub {
            my $init = shift->object->package->can('init') or return 1;
            $init->(@_);
        },
        name     => 'api.engine.initSubroutine',
        priority => 100
    );

    # default void handler.
    $mod->register_callback(void => sub {
            my $void = shift->object->package->can('void') or return 1;
            $void->(@_);
        },
        name     => 'api.engine.voidSubroutine',
        priority => 100
    );

    # registered callback.
    Evented::Object::add_class_monitor($mod->{package}, $mod);
    $mod->register_callback('monitor:register_callback' => sub {
        my ($event, $eo, $event_name, $cb) = @_;
        my $mod = $event->object;

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
    $mod->register_callback('monitor:delete_event' => sub {
        my ($event, $eo, $event_name) = @_;
        my $mod = $event->object;
        $mod->_log("Event: $event_name (all callbacks) deleted from ".(ref($eo) || $eo));
        $mod->list_store_remove_matches('managed_events', sub {
            my $e = shift;
            return 1 if not defined $e->[0]; # disposed
            return unless $eo         == $e->[0];
            return unless $event_name eq $e->[1];
            return 1;
        });
    });

    # deleted a specific callback.
    $mod->register_callback('monitor:delete_callback' => sub {
        my ($event, $eo, $event_name, $cb_name) = @_;
        my $mod = $event->object;
        $mod->_log("Event: $event_name ($cb_name) deleted from ".(ref($eo) || $eo));
        $mod->list_store_remove_matches('managed_events', sub {
            my $e = shift;
            return 1 if not defined $e->[0]; # disposed
            return unless $eo         == $e->[0];
            return unless $event_name eq $e->[1];
            return unless $cb_name    eq $e->[2];
            return 1;
        }, 1);
    });

    # unload handler for destroying events callbacks.
    $mod->register_callback(unload => sub {
        my $done; my $mod = shift->object;
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

sub get_symbol {
    my ($mod, $symbol) = @_;
    return Evented::API::Hax::get_symbol_maybe($mod->{package}, $symbol);
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

    # add weakly to submodules list. hold weak reference to parent module.
    if ($ret) {
        my $a = $mod->{submodules} ||= [];
        push @$a, $ret;
        weaken($a->[$#$a]);
        weaken($ret->{parent} = $mod);
    }

    return $ret;
}

sub unload_submodule {
    my ($mod, $submod) = @_;
    my $submod_name = $submod->name;
    $mod->_log("Unloading submodule $submod_name");

    # unload
    $mod->api->{indent}++;

        # ($api, $mod, $unload_dependents, $force, $unloading_submodule, $reloading)
        #
        # do not force, as that might unload the parent
        # but do say we are unloading a submodule so it can be unloaded independently
        #
        $mod->api->unload_module($submod, 1, undef, 1, undef);

    $mod->api->{indent}--;

    # remove from submodules
    if (my $submods = $mod->{submodules}) {
        @$submods = grep { $_ != $submod } @$submods;
    }
    delete $submod->{parent};

    return 1;
}

sub add_companion_submodule {
    my ($mod, $mod_name, $submod_name) = @_;
    my $api = $mod->api;

    # postpone load until the companion is loaded.
    my $waits = $api->{companion_waits}{$mod_name} ||= [];
    my $ref = [ $mod, $submod_name ]; weaken($ref->[0]);
    push @$waits, $ref;

    # if it is already loaded, go ahead and load the submodule.
    if (my $loaded = $api->get_module($mod_name)) {
        $api->_load_companion_submodules($loaded);
    }

    # false return indicates not yet loaded.
    return;

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
            last if $max && $removed == $max;
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
