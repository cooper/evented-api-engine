# Copyright (c) 2016, Mitchell Cooper
#
# the Evented API Engine is in charge of loading and unloading modules.
# it also handles dependencies and feature availability.
#
package Evented::API::Engine;

use warnings;
use strict;
use 5.010;

use JSON::XS;
use Scalar::Util qw(weaken blessed);
use Module::Loaded qw(mark_as_loaded is_loaded);
use Evented::Object;
use parent 'Evented::Object';

our $VERSION = '4.00';

use Evented::API::Module;
use Evented::Object::Hax qw(set_symbol make_child);

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

    # determine module search directories.
    my ($provided, @inc);
    if ($provided = delete $opts{mod_inc}) {
        @inc = @$provided     if ref $provided eq 'ARRAY';  # dir list
        @inc = $provided      if !@inc;                     # one dir
    }

    # fall back to default directories
    else {
        # current directory, mod directory, submodule mod directory
        @inc = ('.', 'mod', 'lib/evented-api-engine/mod');
    }

    # create the API Engine.
    my $api = bless {
        %opts,
        mod_inc  => \@inc,
        features => [],
        loaded   => [],
        indent   => 0
    }, $class;

    # log subroutine.
    $api->on(log => sub {
        my $api = shift;
        $api->{log_sub}(@_) if $api->{log_sub};
    }, 'api.engine.logSub');

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
# returns the modules that loaded.
sub load_modules_initially {
    my ($api, @mod_names) = @_;
    return $api->load_modules(@mod_names);
}

# load several modules in a group.
# returns the modules that loaded.
sub load_modules {
    my ($api, @mod_names) = @_;
    $api->{load_block} = { in_block => 1 };

    # load each module from within a load block.
    my @results = grep $_, map $api->load_module($_), @mod_names;

    delete $api->{load_block};
    return @results;
}

# $api->load_module()
# loads a module.
#
#   $mod_name       the name of the module.
#
#   $dirs           search directories. this can be omitted; in such a case the
#                   the directories in $api->{mod_inc} will be searched.
#
#   $is_submodule   for internal use. true when the module being loaded is a
#                   submodule. this is used by $mod->load_submodule().
#
#   $reloading      for internal use. true when the module will be reloaded.
#                   this is used by $api->reload_module().
#
sub load_module {
    my ($api, $mod_name, $dirs, $is_submodule, $reloading) = @_;
    return unless $mod_name;
    $api->L($mod_name, 'Loading') unless $dirs;


    # PRE-LOAD CHECKS
    #------------------------

    # check that the module load has not been attempted recently.
    if ($api->{load_block} && !$is_submodule && !$dirs) {

        # make sure this module has not been attempted during this load block.
        if ($api->{load_block}{$mod_name}) {
            $api->L($mod_name,
                'Load FAILED: Skipping already attempted module');
            return;
        }

        # add to attempted list.
        $api->{load_block}{$mod_name}++;
    }

    # check that the module is not currently loaded.
    if (!$is_submodule && $api->module_loaded($mod_name)) {
        $api->L($mod_name, 'Load FAILED: Module already loaded');
        return;
    }

    # if there is no list of search directories, use the default inc.
    if (!$dirs) {
        my @inc = @{ $api->{mod_inc} }; # explicitly make a copy
        return $api->load_module($mod_name, \@inc, @_[3..$#_]);
    }

    # use the next-available search directory.
    # if no search directory is available, we have already checked them all.
    my $search_dir = shift @$dirs;
    if (!defined $search_dir) {
        $api->L($mod_name, 'Load FAILED: Module not found');
        return;
    }

    # LOCATE MODULE
    #------------------------

    $api->L($mod_name, "Searching for module: $search_dir/");

    # the file name is the module name with :: mapped to /.
    # the "last name" of the module is the last portion of the filename.
    my $mod_name_file  = $mod_name; $mod_name_file =~ s/::/\//g;
    my $mod_last_name  = pop @{ [ split '/', $mod_name_file ] };

    # try to locate the module.
    # given some module AB::CD
    #
    # look for $DIR/AB/CD.module
    # look for $DIR/AB/CD/CD.module
    #
    my $mod_dir_1 = "$search_dir/$mod_name_file.module";
    my $mod_dir_2 = "$search_dir/$mod_name_file/$mod_last_name.module";
    my $mod_dir;

    if    (-d $mod_dir_1) { $mod_dir = $mod_dir_1 }
    elsif (-d $mod_dir_2) { $mod_dir = $mod_dir_2 }

    # we could not find the module in this search directory. try the next one.
    else {
        return $api->load_module(@_);
    }


    # RETRIVE METADATA
    #------------------------

    # we located the module directory.
    # now we must ensure all required files are present.
    $api->L($mod_name, "Located module: $mod_dir");
    foreach my $file ("$mod_last_name.pm") {
        next if -f "$mod_dir/$file";
        $api->L($mod_name, "Load FAILED: Required file '$file' missing");
        return;
    }

    # fetch module information. this will be read from a JSON manifest OR
    # from the comments atop the module code if we're in developer mode.
    # give up on loading if we can't retrieve it.
    my $info = $api->_get_module_info($mod_name, $mod_dir, $mod_last_name);
    return if !$info || ref $info ne 'HASH';
    my $pkg = $info->{package} or return;


    # LOAD DEPENDENCIES
    #------------------------

    # load required module dependencies here.
    # consider: if the module fails to load, the dependencies remain loaded.
    $api->_load_module_requirements($info) or return;


    # CREATE MODULE OBJECT
    #------------------------

    # make the module package a child of Evented::API::Module
    # unless 'no_bless' is true.
    my $constructor = 'Evented::API::Module';
    unless ($info->{no_bless}) {
        make_child($pkg, $constructor);
        $pkg->isa($constructor) or return;
        $constructor = $pkg;
    }

    # create the module object.
    my $mod = $constructor->new(
        %$info,
        dir => $mod_dir,
        reloading => $reloading
    );

    # the constructor returned bogus or nothing.
    if (!$mod || !$mod->isa('Evented::API::Module')) {
        $api->L($mod_name, "Constructor $constructor->new() failed");
        _package_unload($pkg);
        return;
    }

    # Safe point - the module object is available and safe for use.
    # add it to the list of loaded modules.
    push @{ $api->{loaded} }, $mod;

    # store dependecy module objects.
    $mod->{dependencies} = [
        map { $api->get_module($_) }
        @{ $info->{depends}{modules} || [] }
    ];

    # make the API Engine listen to the events of the module.
    # hold a weak reference to the API engine.
    $mod->add_listener($api, 'module');
    weaken($mod->{api} = $api);

    # here we fire an event which will export symbols for convenient use
    # within the module package. see Module.pm for defaults.
    $mod->fire(set_variables => $pkg);


    # EVALUATE
    #------------------------

    my $return;
    $mod->L("Evaluating $mod_last_name.pm");
    {

        # disable warnings on redefinition.
        no warnings 'redefine';

        # capture other warnings.
        local $SIG{__WARN__} = sub {
            my $warn = shift;
            chomp $warn;
            $mod->L("WARNING: $warn");
        };

        # do() the file.
        $return = do "$mod_dir/$mod_last_name.pm";

    }

    # an error occurred in loading.
    if (!$return || $return != $mod) {
        my $error = $@ || $! || 'Package did not return module object';
        $mod->L('Load FAILED: '.$error);
        $api->_abort_module_load($mod);
        return;
    }


    # INITIALIZE
    #------------------------

    # initialize the module. returns false on fail.
    $mod->_do_init or return;

    # Safe point - the module will certainly remain loaded.


    # POST-LOAD
    #------------------------

    # fire the 'load' event to indicate it has finished loading.
    $mod->fire('load');
    $mod->L("Loaded successfully ($$mod{version})");

    # mark the package as loaded.
    mark_as_loaded($mod->{package})
        unless is_loaded($mod->{package});

    # load postponed companion submodules, if any.
    $api->_load_companion_submodules($mod);

    return $mod;
}

# loads the modules a module depends on.
sub _load_module_requirements {
    my ($api, $info) = @_;
    my $mod_name = $info->{name}{full};

    # find the names of module dependencies.
    my $dep_names = $info->{depends}{modules} or return 1;
    $dep_names = $info->{depends}{modules} = [ $dep_names ]
        if ref $dep_names ne 'ARRAY';

    # check each dependency.
    foreach my $dep_name (@$dep_names) {

        # dependency already loaded.
        if ($api->module_loaded($dep_name)) {
            $api->L($mod_name,
                "Requirements: Dependency $dep_name already loaded");
            next;
        }

        # prevent endless loops.
        if ($info->{name} eq $dep_name) {
            $api->L($mod_name, 'Requirements: Module depends on itself');
            next;
        }

        # load the dependency.
        $api->L($mod_name, "Requirements: Loading dependency $dep_name");
        $api->{indent}++;
            my $ok = $api->load_module($mod_name);
        $api->{indent}--;

        # something went wrong.
        next if $ok;
        $api->L($mod_name,
            "Load FAILED: Loading dependency $dep_name failed");
        return;
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
        $api->L($mod_name, "No JSON manifest found at $path");
        $info = {};
    }

    # parse JSON.
    elsif (not $info = eval { $json->decode($info) }) {
        $api->L($mod_name, "Load FAILED: JSON parsing of $path failed: $@");
        $api->L($mod_name, "JSON text: $slurp");
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

    $api->L($mod_name, 'Scanning for metadata');

    # try reading comments.
    open my $fh, '<', "$mod_dir/$mod_last_name.pm"
        or $api->L($mod_name, "Load FAILED: Could not open file: $!")
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
                    $api->L($mod_name,
                        "Load FAILED: Evaluating '\@$var_name' failed: $@");
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
            $api->L($mod_name,
                "Upgrade: $old_version -> $$info{version} (automatic)");
        }
        elsif ($info->{version} != $old_version) {
            $api->L($mod_name, "Upgrade: $old_version -> $$info{version}");
        }

        # open
        open $fh, '>', "$mod_dir/$mod_last_name.json" or
            $api->L($mod_name,
                "JSON warning: Could not write module JSON information"
            ) and return;

        # encode
        my $info_json = $json->encode($info);

        # write
        $fh->write($info_json);
        close $fh;

        $api->L($mod_name, "JSON: Updated module information file");

    }

    $info->{version} //= $old_version;
    $info->{name} = { full => $info->{name} } if !ref $info->{name};
    return $info;
}

# remove the module from the 'loaded' list and delete its symbol table.
sub _abort_module_load {
    my ($api, $mod) = @_;
    @{ $api->{loaded} } = grep { $_ != $mod } @{ $api->{loaded} };
    _package_unload($mod->{package}) if $mod->{package};
    %$mod = ();
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
    my ($api, $mod, $unload_dependents, $force,
        $unloading_submodule, $reloading) = @_;

    # not blessed, find the module.
    if (!blessed $mod) {
        $mod = $api->get_module($mod);
        if (!$mod) {
            $api->L($_[1], 'Unload: not loaded');
            return;
        }
    }


    # PRE-UNLOAD CHECKS
    #------------------------

    # if this is a submodule, it cannot be unloaded this way.
    if ($mod->{parent} && !$unloading_submodule) {

        # if we're forcing to unload, we just gotta unload the parent.
        # this module will be unloaded because of $unload_dependents, so return.
        if ($force) {
            $api->unload_module($mod->{parent}, 1, 1);
        }

        # not forcing unload. give up.
        else {
            $mod->L(
                'Unload: submodule cannot be unloaded independently '.
                'of parent'
            );
        }

        return;
    }

    my $mod_name = $mod->name;
    $mod->L('Unloading');

    # check if any loaded modules are dependent on this one.
    # if we're unloading recursively, do so after voiding.
    my @dependents = $mod->dependents;
    if (!$unload_dependents && @dependents) {
        my $dependents = join ', ', map { $_->name } @dependents;
        $mod->L("Can't unload: Dependent modules: $dependents");
        return;
    }


    # VOID
    #------------------------

    # fire module void. if the fire was stopped, give up.
    $mod->_do_void($unloading_submodule);


    # UNLOAD DEPENDENCIES
    #------------------------

    # if we're unloading recursively, do so now.
    if ($unload_dependents && @dependents) {
        $mod->L("Unloading dependent modules");
        $api->{indent}++;
        $api->unload_module($_, 1, 1, undef, $reloading) foreach @dependents;
        $api->{indent}--;
    }

    # Safe point: from here, we can assume it will be unloaded for sure.

    # if we're reloading, add to unloaded list.
    push @{ $api->{r_unloaded} }, $mod->name
        if $reloading && !$mod->{parent};

    # unload submodules.
    $api->unload_module($_, 1, 1, 1, $reloading) foreach $mod->submodules;


    # POST-UNLOAD
    #------------------------

    # fire event for module unloaded (after void succeded)
    $mod->fire('unload');

    # remove from loaded list.
    @{ $api->{loaded} } = grep { $_ != $mod } @{ $api->{loaded} };

    # delete all events in case of cyclical references.
    $mod->delete_all_events();

    # prepare for destruction.
    $mod->{UNLOADED} = 1;
    bless $mod, 'Evented::API::Module';
    $mod->L("Destroying package $$mod{package}");

    # clear the symbol table of this module.
    # if preserve_sym is set and this is during reload, don't delete symbols.
    package_unload($mod->{package})
        unless $mod->{preserve_sym} && $reloading;

    $api->L($mod_name, 'Unloaded successfully');
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
                $api->L($_[1], 'Reload: not loaded');
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

sub _add_companion_submodule_wait {
    my ($api, $mod, $mod_name, $submod_name) = @_;

    # postpone load until the companion is loaded.
    # hold a weak reference to the module waiting.
    my $waits = $api->{companion_waits}{$mod_name} ||= [];
    my $ref = [ $mod, $submod_name ]; weaken($ref->[0]);
    push @$waits, $ref;

    # if it is already loaded, go ahead and load the submodule.
    if (my $loaded = $api->get_module($mod_name)) {
        return $api->_load_companion_submodules($loaded);
    }

    # false return indicates not yet loaded.
    return;
}

sub _load_companion_submodules {
    my ($api, $mod) = @_;
    my $waits = $api->{companion_waits}{ $mod->name } or return;
    ref $waits eq 'ARRAY' or return;

    my $status;
    foreach (@$waits) {
        my ($parent_mod, $submod_name) = @$_;

        # load it
        $parent_mod->L("Loading companion submodule");
        my $submod = $parent_mod->load_submodule($submod_name);

        # when this mod unloads, unload the submodule
        if ($submod) {
            $submod_name = $submod->name;

            # create weak references for the callback
            weaken(my $weak_submod     = $submod);
            weaken(my $weak_parent_mod = $parent_mod);

            # attach an unload callback
            $mod->on(unload => sub {
                return if !$weak_parent_mod || !$weak_submod;
                $weak_parent_mod->L('Unloading companion submodule');
                $weak_parent_mod->unload_submodule($weak_submod);
            }, name => "companion.$submod_name");

            $status = 1;
        }
        else {
            $parent_mod->L('Companion submodule failed to load');
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

*_log = *L;

# API log.
sub L {
    my ($api, $pfx, $msg) = @_;

    # add the prefix.
    $msg = defined $msg ? "[$pfx] $msg" : $pfx;

    # log the first line.
    my @msgs = split $/, $msg;
    $api->fire(log => ('    ' x $api->{indent}).shift(@msgs));

    # log all other lines like "... text"
    my $i = $api->{indent} + 1;
    while (my $next = shift @msgs) {
        $api->fire(log => ('    ' x $i)."... $next");
    }

    return 1;
}

# unload a package and delete its symbols.
# package_unload('My::Package')
sub _package_unload {
    my $class = shift;
    no strict 'refs';
    @{ $class . '::ISA' } = ();

    my $symtab = $class.'::';
    for my $symbol (keys %$symtab) {
        next if $symbol =~ /\A[^:]+::\z/;
        delete $symtab->{$symbol};
    }

    mark_as_unloaded($class) if is_loaded($class);
    return 1;
}

# read contents of file.
sub _slurp {
    my ($api, $log_type, $mod_name, $file_name) = @_;

    # open file.
    my $fh;
    if (!open $fh, '<', $file_name) {
        return unless $log_type;
        $api->L($file_name, 'Could not open for reading');
        return;
    }

    # read and close file.
    local $/ = undef;
    my $data = <$fh>;
    close $fh;

    return $data;
}

1;
