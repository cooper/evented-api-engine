# Copyright (c) 2016, Mitchell Cooper
# Module represents an API module and provides an interface for managing one.
package Evented::API::Module;

use warnings;
use strict;
use 5.010;

use Evented::Object;
use parent 'Evented::Object';

use Scalar::Util qw(blessed weaken);
use List::Util qw(first);

our $VERSION = '4.03';

sub new {
    my ($class, %opts) = @_;
    my $mod = bless \%opts, $class;
    Evented::API::Events::add_events($mod);
    return $mod;
}

sub name       { shift->{name}{full}            }
sub package    { shift->{package}               }
sub api        { shift->{api}                   }
sub parent     { shift->{parent}                }
sub submodules { @{ shift->{submodules} || [] } }

sub Log {
    my $mod = shift;
    $mod->api->Log($mod->name, "@_");
}

sub _log;
*_log = *Log;

sub get_symbol {
    my ($mod, $symbol) = @_;
    return Evented::Object::Hax::get_symbol($mod->{package}, $symbol);
}

sub _do_init {
    my $mod = shift;
    my $api = $mod->api;

    # fire module initialize.
    $api->Log($mod->name, 'Initializing');
    $api->{indent}++;
        my $init_fire = $mod->prepare('init')->fire('return_check');
    $api->{indent}--;

    # init was stopped. cancel the load.
    if (my $stopper = $init_fire->stopper) {
        $mod->Log('init stopped: '.$init_fire->stop);
        $mod->Log("Load FAILED: Initialization canceled by '$stopper'");

        $api->_abort_module_load($mod);

        # fire unload so that bases can undo whatever was done up
        # to the fail point of init.
        bless $mod, 'Evented::API::Module';
        $mod->fire('unload');

        return;
    }

    # init was successful
    return 1;
}

sub _do_void {
    my ($mod, $unloading_submodule) = @_;
    my $api = $mod->api;

    # fire module void.
    # consider: should this have return_check like init?
    $mod->Log('Voiding');
    my $void_fire = $mod->fire('void');

    # init was stopped. cancel the unload.
    my $stopper = $void_fire->stopper;
    if (!$unloading_submodule && $stopper) {
        $mod->Log("void stopped: ".$void_fire->stop);
        $mod->Log("Can't unload: canceled by '$stopper'");
        return;
    }

    # if this is a submodule, it isn't allowed to refuse to unload.
    elsif ($stopper) {
        $mod->Log(
            "Warning! This submodule has requested to remain ".
            'loaded, but submodules MUST be unloaded with their parent'
        );
    }

    # void was successful
    return 1;

}

##################
### SUBMODULES ###
##################

sub load_submodule {
    my ($mod, $mod_name) = @_;
    $mod->Log("Loading submodule $mod_name");

    # call ->load_module with the search dir set to the
    # parent module's main directory.
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
    my ($mod, $submod, $reloading) = @_;
    my $submod_name = $submod->name;
    $mod->Log("Unloading submodule $submod_name");

    # unload
    $mod->api->{indent}++;

        # ($mod, $unload_dependents, $force, $unloading_submodule, $reloading)
        #
        # do not force, as that might unload the parent
        # but do say we are unloading a submodule so it can be unloaded
        # independently (which usually wouldn't be allowed)
        #
        $mod->api->unload_module($submod, undef, undef, 1, $reloading);

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
    $mod->api->_add_companion_submodule_wait($mod, $mod_name, $submod_name);
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

####################
### DEPENDENCIES ###
####################

# returns the modules that this depends on.
sub dependencies {
    return @{ shift->{dependencies} || [] };
}

# returns the modules that this companion submodule depends on.
sub companions {
    return @{ shift->{companions} || [] };
}

# returns the top-level modules that depend on this.
sub dependents {
    my $mod = shift;
    my @mods;
    foreach my $m (@{ $mod->api->{loaded} }) {
        next unless first { $_ == $mod } $m->dependencies;
        push @mods, $m;
    }
    return @mods;
}

# returns the companion submodules that depend on this.
sub dependent_companions {
    my $mod = shift;
    my @mods;
    foreach my $m (@{ $mod->api->{loaded} }) {
        next unless first { $_ == $mod } $m->companions;
        push @mods, $m;
    }
    return @mods;
}

1;
