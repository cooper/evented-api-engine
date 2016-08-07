# Copyright (c) 2013 Mitchell Cooper
# the API Engine is in charge of loading and unloading modules.
# It also handles dependencies and feature availability.
package Evented::API::Engine;

use warnings;
use strict;
use 5.010;

use JSON::XS ();
use Scalar::Util   qw(weaken blessed);
use Module::Loaded qw(mark_as_loaded is_loaded);
use Evented::Object;
use parent 'Evented::Object';

our $VERSION; BEGIN { $VERSION = '3.97' }

use Evented::API::Module;
use Evented::API::Hax qw(set_symbol make_child package_unload);


# create a new API Engine.
#
# Evented::API::Engine->new(
#     mod_inc  => ['mod', '/usr/share/something/mod'],
#     features => qw(io-async something-else),
#     modules  => $conf->keys_for_block('modules')
# );
#
sub new {
    my ($class, %opts) = @_;

    # determine search directories.
    my $inc =                                                       #
        defined $opts{mod_inc} && ref $opts{mod_inc} eq 'ARRAY' ?   # list
        $opts{mod_inc}                                          :   #
        defined $opts{mod_inc}                                  ?   # single
        [ $opts{mod_inc} ]                                      :   #
        ['.', 'mod', 'lib/evented-api-engine/mod'];                 # defaults
                                                                    #
    # create the API Engine.
    my $api = bless {
        %opts,
        mod_inc  => $inc,
        features => [],
        loaded   => [],
        indent   => 0
    }, $class;

    # log subroutine.
    $api->register_callback(log => sub {
        my $api = $_[0]->object;
        $api->{log_sub}(@_) if $api->{log_sub};
    });

    $api->_configure_api(%opts);
    return $api;
}

# handles post-construct constructor arguments.
#
#    features   =>  automatic ->add_feature()s
#    modules    =>  automatic ->load_module()s
#
sub _configure_api {
    my ($api, %opts) = @_;

    # automatically add features.
    if (defined $opts{features}) {
        $api->add_feature($_) foreach @{
            ref $opts{features} eq 'ARRAY' ?
            $opts{features}                :
            [ $opts{features} ]
        };
    }

    # automatically load modules.
    if (defined $opts{modules}) {
        $api->load_modules_initially(@{
            ref $opts{modules} eq 'ARRAY' ?
            $opts{modules}                :
            [ $opts{modules} ]
        });
    }

    return 1;
}

#######################
### LOADING MODULES ###
#######################

# load modules initially, i.e. from a configuration file.
# returns the module that loaded.
sub load_modules_initially {
    my ($api, @mod_names) = @_;
    $api->load_modules(@mod_names);
}

# load several modules in a group.
# returns the module names that loaded.
sub load_modules {
    my ($api, @mod_names) = @_;
    $api->{load_block} = { in_block => 1 };

    # load each module from within a load block.
    my @results;
    push @results, $api->load_module($_) foreach @mod_names;

    delete $api->{load_block};
    return grep { $_ } @results;
}

# load a module.
sub load_module {
    my ($api, $mod_name, $dirs, $is_submodule, $reloading) = @_;
    return unless $mod_name;
    $api->_log("[$mod_name] Loading") unless $dirs;

    # we are in a load block.
    # we are not in the middle of loading this particular module.
    if (!$is_submodule && $api->{load_block} && !$dirs) {

        # make sure this module has not been attempted.
        if ($api->{load_block}{$mod_name}) {
            $api->_log("[$mod_name] Load FAILED: Skipping already attempted module");
            return;
        }

        # add to attempted list.
        $api->{load_block}{$mod_name} = 1;

    }

    # check here if the module is loaded already.
    if (!$is_submodule && $api->module_loaded($mod_name)) {
        $api->_log("[$mod_name] Load FAILED: Module already loaded");
        return;
    }

    # if there is no list of search directories, we have not attempted any loading.
    if (!$dirs) {
        return $api->load_module($mod_name, [ @{ $api->{mod_inc} } ], $is_submodule, $reloading);
        # to prevent modification
    }

    # otherwise, we are searching the next directory in the list.
    my $search_dir = shift @$dirs;

    # already checked every search directory.
    if (!defined $search_dir) {
        $api->_log("[$mod_name] Load FAILED: Module not found in any search directories");
        return;
    }

    $api->_log("[$mod_name] Searching for module: $search_dir/");

    # module does not exist in this search directory.
    # try the next search directory.
    my $mod_name_file  = $mod_name; $mod_name_file =~ s/::/\//g;
    my $mod_last_name  = pop @{ [ split '/', $mod_name_file ] };

    # try to locate.
    # example (Some::Module):
    #    Some/Module.module
    #    Some/Module/Module.module
    my $mod_dir;
    my $mod_dir_1      = "$search_dir/$mod_name_file.module";
    my $mod_dir_2      = "$search_dir/$mod_name_file/$mod_last_name.module";
    if    (-d $mod_dir_1) { $mod_dir = $mod_dir_1 }
    elsif (-d $mod_dir_2) { $mod_dir = $mod_dir_2 }
    else                  { return $api->load_module($mod_name, $dirs, $is_submodule) }

    # we located the module directory.
    # now we must ensure all required files are present.
    $api->_log("[$mod_name] Located module: $mod_dir");
    foreach my $file ("$mod_last_name.pm") {
        next if -f "$mod_dir/$file";
        $api->_log("[$mod_name] Load FAILED: Mandatory file '$file' not present");
        return;
    }

    # fetch module information.
    my $info = $api->_get_module_info($mod_name, $mod_dir, $mod_last_name);
    return if not defined $info;
    my $pkg = $info->{package} or return;

    # load required modules here.
    # FIXME: if these are loaded, then the module fails later, these remain loaded.
    $api->_load_module_requirements($info) or return;

    # make the package a child of Evented::API::Module
    # unless 'nobless' is true.
    my $new = 'Evented::API::Module';
    unless ($info->{no_bless}) {
        make_child($pkg, 'Evented::API::Module');
        $new = $pkg;
    }

    # create the module object.
    $info->{name}{last} = $mod_last_name;
    my $mod = $new->new(%$info, dir => $mod_dir);
    push @{ $api->{loaded} }, $mod;

    # add dependencies.
    $mod->{dependencies} = [
        map { $api->get_module($_) }
        @{ $info->{depends}{modules} || [] }
    ];

    # make engine listener of module.
    $mod->add_listener($api, 'module');

    # hold a weak reference to the API engine.
    weaken($mod->{api} = $api);

    # export API Engine and module objects.
    $mod->register_callback(set_variables => sub {
        set_symbol($pkg, {
            '$api'      => $api,
            '$mod'      => shift->object,
            '$VERSION'  => $info->{version}
        });
    }, name => 'api.engine.setVariables');
    $mod->fire_event('set_variables', $pkg);

    # load the module.
    my $return;
    $api->_log("[$mod_name] Evaluating main package");
    {

        # disable warnings on redefinition.
        # note: this does not work as I want it to.
        # it has to be inside eval to disable redefine warnings for some reason.
        # see: http://perldoc.perl.org/perldiag.html
        no warnings 'redefine';

        # capture other warnings.
        local $SIG{__WARN__} = sub {
            my $warn = shift;
            chomp $warn;
            $api->_log("[$mod_name] WARNING: $warn");
        };

        # do() the file.
        $return = do "$mod_dir/$mod_last_name.pm";

    }

    # probably an error, or the module just didn't return $mod.
    if (!$return || $return != $mod) {
        $api->_log("[$mod_name] Load FAILED: ".($@ || $! || 'Package did not return module object'));
        @{ $api->{loaded} } = grep { $_ != $mod } @{ $api->{loaded} };
        package_unload($pkg);
        return;
    }

    # fire module initialize. if the fire was stopped, give up.
    $mod->{reloading} = $reloading;
    $api->_log("[$mod_name] Initializing");
    $api->{indent}++;
    if (my $stopper = (my $fire = $mod->prepare('init')->fire('return_check'))->stopper) {
        $api->_log("[$mod_name] init stopped: ".$fire->stop);
        $api->_log("[$mod_name] Load FAILED: Initialization canceled by '$stopper'");

        # remove the module; unload the package.
        @{ $api->{loaded} } = grep { $_ != $mod } @{ $api->{loaded} };
        package_unload($pkg);

        # fire unload so that bases can undo whatever was done up
        # to the fail point of init.
        bless $mod, 'Evented::API::Module';
        $mod->fire_event('unload');

        $api->{indent}--;
        return;
    }

    $api->{indent}--;
    $mod->fire_event('load');
    $api->_log("[$mod_name] Loaded successfully ($$mod{version})");
    mark_as_loaded($mod->{package}) unless is_loaded($mod->{package});

    # load companions, if any.
    $api->_load_companion_submodules($mod);

    return $mod;
}

# loads the modules a module depends on.
sub _load_module_requirements {
    my ($api, $info) = @_;

    #
    # TODO: @depends.submodules: autoload submodules.
    #       different than @depends.modules in that
    #       it will allow the whole thing to be unloaded
    #       at once, regardless of whether the submodules
    #       "depend" on the parent (all will automatically)
    #

    # module does not depend on any other modules.
    my $mods = $info->{depends}{modules} or return 1;

    $info->{depends}{modules} = [$mods] if ref $mods ne 'ARRAY';
    foreach my $mod_name (@{ $info->{depends}{modules} }) {

        # dependency already loaded.
        if ($api->module_loaded($mod_name)) {
            $api->_log("[$$info{name}{full}] Requirements: Dependency $mod_name already loaded");
            next;
        }

        # prevent endless loops.
        if ($info->{name} eq $mod_name) {
            $api->_log("[$$info{name}{full}] Requirements: Module depends on itself");
            next;
        }

        # load the dependency.
        $api->_log("[$$info{name}{full}] Requirements: Loading dependency $mod_name");
        $api->{indent}++;
        if (!$api->load_module($mod_name)) {
            $api->_log("[$$info{name}{full}] Load FAILED: loading dependency $mod_name failed");
            $api->{indent}--;
            return;
        }
        $api->{indent}--;
    }

    return 1;
}

my $json = JSON::XS->new->canonical->pretty;

# fetch module information.
sub _get_module_info {
    my ($api, $mod_name, $mod_dir, $mod_last_name) = @_;

    # try reading module JSON file.
    my $path = "$mod_dir/$mod_last_name.json";
    my $info = my $slurp = $api->_slurp(undef, $mod_name, $path);

    # no file - start with an empty hash.
    if (!length $info) {
        $api->_log("[$mod_name] No JSON manifest found at $path");
        $info = {};
    }

    # parse JSON.
    elsif (not $info = eval { $json->decode($info) }) {
        $api->_log("[$mod_name] Load FAILED: JSON parsing of module info ($path) failed: $@");
        $api->_log("[$mod_name] JSON text: $slurp");
        return;
    }

    # JSON was valid. now let's check the modified times.
    else {
        my $pkg_modified = (stat "$mod_dir/$mod_last_name.pm"  )[9];
        my $man_modified = (stat "$mod_dir/$mod_last_name.json")[9];

        # if not in developer mode, always use manifest.
        #
        # or the manifest file is more recent or equal to the package file.
        # the JSON info is therefore up-to-date
        #
        if (!$api->{developer} || $man_modified >= $pkg_modified) {
            $info->{name} = { full => $info->{name} } if !ref $info->{name};
            return $info;
        }

    }

    $api->_log("[$mod_name] Scanning for metadata");

    # try reading comments.
    # TODO: it would be nice if this also had the wikifier boolean syntax @something;
    open my $fh, '<', "$mod_dir/$mod_last_name.pm"
        or $api->_log("[$mod_name] Load FAILED: Could not open file: $!")
        and return;

    # parse for variables.
    my $old_version = delete $info->{version} || 0;
    while (my $line = <$fh>) {
        next unless $line =~ m/^#\s*@([\.\w]+)\s*:(.+)$/;
        my ($var_name, $perl_value) = ($1, $2);

        # find the correct hash level.
        my ($i, $current, @s) = (0, $info, split /\./, $var_name);
        foreach my $l (@s) {

            # last level, should contain the value.
            if ($i == $#s) {
                $current->{$l} = eval $perl_value;
                if (!$current->{$l} && $@) {
                    $api->_log("[$mod_name] Load FAILED: Evaluating '\@$var_name' failed: $@");
                    return;
                }
                last;
            }

            # set the current level.
            $current = ( $current->{$l} ||= {} );
            $i++;

        }

    }
    close $fh;

    # if in developer mode, write the changes.
    if ($api->{developer}) {

        # automatic versioning.
        if (!defined $info->{version}) {
            $info->{version} = $old_version + 0.1;
            $api->_log("[$mod_name] Upgrade: $old_version -> $$info{version} (automatic)");
        }
        elsif ($info->{version} != $old_version) {
            $api->_log("[$mod_name] Upgrade: $old_version -> $$info{version}");
        }

        # open
        open $fh, '>', "$mod_dir/$mod_last_name.json" or
            $api->_log("[$mod_name] JSON warning: Could not write module JSON information")
            and return;

        # encode
        my $info_json = $json->encode($info);

        # write
        $fh->write($info_json);
        close $fh;

        $api->_log("[$mod_name] JSON: Updated module information file");

    }

    $info->{version} //= $old_version;
    $info->{name} = { full => $info->{name} } if !ref $info->{name};
    return $info;
}

#########################
### UNLOADING MODULES ###
#########################

# unload a module.
# returns the NAME of the module unloaded.
#
# $unload_dependents = recursively unload all dependent modules as well
# $force = if the module is a submodule, force it to unload by unloading parent also
#
# For internal use only:
#
# $unloading_submodule = means the parent is unloading a submodule
# $reloading = means the module is reloading
#
#
sub unload_module {
    my ($api, $mod, $unload_dependents, $force, $unloading_submodule, $reloading) = @_;

    # not blessed, search for module.
    if (!blessed $mod) {
        $mod = $api->get_module($mod);
        if (!$mod) {
            $api->_log("[$_[1]] Unload: not loaded");
            return;
        }
    }

    # if this is a submodule, it cannot be unloaded this way.
    if ($mod->{parent} && !$unloading_submodule) {

        # if we're forcing to unload, we just gotta unload the parent.
        # this module will be unloaded because of $unload_dependents, so return.
        if ($force) {
            $api->unload_module($mod->{parent}, 1, 1);
        }

        # not forcing unload. give up.
        else {
            $mod->_log("Unload: submodule cannot be unloaded independently of parent");
        }

        return;
    }

    my $mod_name = $mod->name;
    $mod->_log('Unloading');

    # check if any loaded modules are dependent on this one.
    # if we're unloading recursively, do so after voiding.
    my @dependents = $mod->dependents;
    if (!$unload_dependents && @dependents) {
        my $dependents = join ', ', map { $_->name } @dependents;
        $mod->_log("Can't unload: Dependent modules: $dependents");
        return;
    }

    # fire module void. if the fire was stopped, give up.
    $mod->_log('Voiding');
    if (my $stopper = (my $fire = $mod->prepare('void')->fire('return_check'))->stopper) {
        $api->_log("[$mod_name] void stopped: ".$fire->stop);
        $api->_log("[$mod_name] Can't unload: canceled by '$stopper'");
        return;
    }

    # if we're unloading recursively, do so now.
    if ($unload_dependents && @dependents) {
        $mod->_log("Unloading dependent modules");
        $api->{indent}++;
        $api->unload_module($_, 1, 1, undef, $reloading) foreach @dependents;
        $api->{indent}--;
    }

    # Safe point: from here, we can assume it will be unloaded for sure.

    # if we're reloading, add to unloaded list.
    push @{ $api->{r_unloaded} }, $mod->name if $reloading && !$mod->{parent};

    # unload submodules.
    $api->unload_module($_, 1, 1, 1, $reloading) foreach $mod->submodules;

    # fire event for module unloaded (after void succeded)
    $mod->fire_event('unload');

    # remove from loaded.
    @{ $api->{loaded} } = grep { $_ != $mod } @{ $api->{loaded} };

    # delete all events in case of cyclical references.
    $mod->delete_all_events();

    # prepare for destruction.
    $mod->{UNLOADED} = 1;
    bless $mod, 'Evented::API::Module';
    $mod->_log("Destroying package $$mod{package}");

    # if preserve_sym is enabled and this is during reload, don't delete symbols.
    package_unload($mod->{package}) unless $mod->{preserve_sym} && $reloading;

    $api->_log("[$mod_name] Unloaded successfully");
    return $mod_name;
}

#########################
### RELOADING MODULES ###
#########################

# reload a module.
sub reload_module {
    my ($api, @mods) = @_;
    my $count = 0;

    # during the reload, any modules unloaded,
    # including dependencies but excluding submodules,
    # will end up in this array.
    $api->{r_unloaded} = [];

    # unload each module provided.
    foreach my $mod (@mods) {

        # not blessed, search for module.
        if (!blessed $mod) {
            $mod = $api->get_module($mod);
            if (!$mod) {
                $api->_log("[$_[1]] Unload: not loaded");
                next;
            }
        }

        # unload the module.
        $mod->{reloading} = 1;
        $api->unload_module($mod, 1, 1, undef, 1) or return;

    }

    # load all of the modules that were unloaded again
    # (if they weren't already loaded, probably as dependencies).
    my $unloaded = delete $api->{r_unloaded};
    while (my $mod_name = shift @$unloaded) {
        next if $api->module_loaded($mod_name);
        $count++ if $api->load_module($mod_name, undef, undef, 1);
    }

    return $count;
}

############################
### COMPANION SUBMODULES ###
############################

sub _load_companion_submodules {
    my ($api, $mod) = @_;
    my $waits = $api->{companion_waits}{ $mod->name } or return;
    ref $waits eq 'ARRAY' or return;

    my $status;
    foreach (@$waits) {
        my ($parent_mod, $submod_name) = @$_;

        # load it
        $parent_mod->_log("Loading companion submodule");
        my $submod = $parent_mod->load_submodule($submod_name);

        # when this mod unloads, unload the submodule
        if ($submod) {
            $submod_name = $submod->name;

            # create weak references for the callback
            weaken(my $weak_submod     = $submod);
            weaken(my $weak_parent_mod = $parent_mod);

            # attach an unload callback
            $mod->register_callback(unload => sub {
                return if !$weak_parent_mod || !$weak_submod;
                $weak_parent_mod->_log("Module with a companion submodule unloaded");
                $weak_parent_mod->unload_submodule($weak_submod);
            }, name => "companion.$submod_name");

            $status = 1;
        }
        else {
            $parent_mod->_log('Companion submodule failed to load');
        }
    }

    delete $api->{companion_waits}{ $mod->name };
    return $status;
}

########################
### FETCHING MODULES ###
########################

# returns the module object of a full module name.
sub get_module {
    my ($api, $mod_name) = @_;
    foreach (@{ $api->{loaded} }) {
        return $_ if $_->name eq $mod_name;
    }
    return;
}

# returns the module object associated with a package.
sub package_to_module {
    my ($api, $package) = @_;
    foreach (@{ $api->{loaded} }) {
        return $_ if $_->package eq $package;
    }
    return;
}

# returns true if the full module name provided is loaded.
sub module_loaded {
    return 1 if shift->get_module(shift);
    return;
}

####################
### DATA STORAGE ###
####################

# store a piece of data specific to this API Engine.
sub store {
    my ($api, $key, $value) = @_;
    $api->{store}{$key} = $value;
}

# fetch a piece of data specific to this API Engine.
sub retrieve {
    my ($api, $key) = @_;
    return $api->{store}{$key};
}

# adds the item to a list store.
# if the store doesn't exist, creates it.
sub list_store_add {
    my ($api, $key, $value) = @_;
    push @{ $api->{store}{$key} ||= [] }, $value;
}

# returns all the items in a list store.
# if the store doesn't exist, this is
# still safe and returns an empty list.
sub list_store_items {
    my ($api, $key) = @_;
    return @{ $api->{store}{$key} || [] };
}

################
### FEATURES ###
################

# enable a feature.
sub add_feature {
    my ($api, $feature) = @_;
    push @{ $api->{features} }, lc $feature;
}

# disable a feature.
sub remove_feature {
    my ($api, $feature) = @_;
    @{ $api->{features} } = grep { $_ ne lc $feature } @{ $api->{features} };
}

# true if a feature is present.
sub has_feature {
    my ($api, $feature) = @_;
    foreach (@{ $api->{features} }) {
        return 1 if $_ eq lc $feature;
    }
    return;
}

#####################
### MISCELLANEOUS ###
#####################

# API log.
sub _log {
    my ($api, $msg) = @_;
    my @msgs = split $/, $msg;
    $api->fire_event(log => ('    ' x $api->{indent}).shift(@msgs));
    my $i = $api->{indent} + 1;
    while (my $next = shift @msgs) {
        $api->fire_event(log => ('    ' x $i)."... $next");
    }
    return 1;
}

# read contents of file.
sub _slurp {
    my ($api, $log_type, $mod_name, $file_name) = @_;

    # open file.
    my $fh;
    if (!open $fh, '<', $file_name) {
        return unless $log_type;
        $api->_log("slurp: $file_name could not be opened for reading");
        return;
    }

    # read and close file.
    local $/ = undef;
    my $data = <$fh>;
    close $fh;

    return $data;
}

1;
