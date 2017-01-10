# Copyright (c) 2016, Mitchell Cooper
package Evented::API::Events;

use warnings;
use strict;
use 5.010;

use Evented::Object;
use parent 'Evented::Object';

use Scalar::Util qw(blessed weaken);
use Evented::Object::Hax qw(set_symbol);

our $VERSION = '4.02';

sub add_events {
    my $mod = shift;

    # default initialize handler.
    $mod->on(init => \&mod_default_init,
        name     => 'api.engine.initSubroutine',
        priority => 100,
        with_eo  => 1
    );

    # default void handler.
    $mod->on(void => \&mod_default_void,
        name     => 'api.engine.voidSubroutine',
        priority => 100,
        with_eo  => 1
    );

    # default variable exports.
    $mod->on(set_variables =>
        \&mod_default_set_variables, 'api.engine.setVariables');

    # make the module a class monitor of the package.
    Evented::Object::add_class_monitor($mod->{package}, $mod);

    # registered callback.
    $mod->on('monitor:register_callback' =>
        \&mod_event_registered, 'api.engine.eventTracker.register');

    # deleted all callbacks for an event.
    $mod->on('monitor:delete_event' =>
        \&mod_event_deleted, 'api.engine.eventTracker.deleteEvent');

    # deleted a specific callback.
    $mod->on('monitor:delete_callback' =>
        \&mod_callback_deleted, 'api.engine.eventTracker.deleteCallback');

    # unload handler for destroying events callbacks.
    $mod->on(unload => \&mod_unloaded,
        'api.engine.eventTracker.unload');

}

sub mod_default_init {
    my $mod = shift;
    my $init = $mod->package->can('init') or return 1;
    return $init->(@_);
}

sub mod_default_void {
    my $mod = shift;
    my $void = $mod->package->can('void') or return 1;
    return $void->(@_);
}

sub mod_default_set_variables {
    my $mod = shift;
    set_symbol($mod->package, {
        '$api'      => $mod->api,
        '$mod'      => $mod,
        '$VERSION'  => $mod->{version}
    });
}

sub mod_event_registered {
    my ($mod, $fire, $eo, $event_name, $cb) = @_;
    my $ref = ref $eo;

    # permanent - ignore.
    if ($cb->{permanent}) {
        $mod->Log("Permanent event: $event_name ($$cb{name}) registered to $ref");
        return;
    }

    # hold weak reference.
    my $e = [ $eo, $event_name, $cb->{name} ];
    weaken($e->[0]);

    $mod->list_store_add('managed_events', $e);
    $mod->Log("Event: $event_name ($$cb{name}) registered to $ref");
}

sub mod_event_deleted {
    my ($mod, $fire, $eo, $event_name) = @_;
    my $ref = ref $eo;
    $mod->Log("Event: $event_name (all callbacks) deleted from $ref");
    $mod->list_store_remove_matches('managed_events', sub {
        my $e = shift;
        return 1 if not defined $e->[0]; # disposed
        return unless $eo         == $e->[0];
        return unless $event_name eq $e->[1];
        return 1;
    });
}

sub mod_callback_deleted {
    my ($mod, $fire, $eo, $event_name, $cb_name) = @_;
    my $ref = ref $eo;
    $mod->Log("Event: $event_name ($cb_name) deleted from $ref");
    $mod->list_store_remove_matches('managed_events', sub {
        my $e = shift;
        return 1 if not defined $e->[0]; # disposed
        return unless $eo         == $e->[0];
        return unless $event_name eq $e->[1];
        return unless $cb_name    eq $e->[2];
        return 1;
    }, 1);
}

sub mod_unloaded {
    my $mod = shift;
    my $done;
    foreach my $e ($mod->list_store_items('managed_events')) {
        my ($eo, $event_name, $name) = @$e;
        my $ref = ref $eo;

        # this is a weak reference --
        # if undefined, it was disposed of.
        return unless $eo;

        # first one.
        if (!$done) {
            $mod->Log('Destroying managed event callbacks');
            $mod->api->{indent}++;
            $done = 1;
        }

        # delete this callback.
        $eo->delete_callback($event_name, $name);
        $mod->Log("Event: $event_name ($name) deleted from $ref");

    }
    $mod->api->{indent}-- if $done;
    return 1;
}

1
