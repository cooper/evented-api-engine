# Copyright (c) 2013 Mitchell Cooper
# the API Engine is in charge of loading and unloading modules.
# It also handles dependencies and feature availability.
package Evented::API::Engine;

use warnings;
use strict;
use 5.010;

use JSON ();
use Scalar::Util 'weaken';

use Evented::Object;
use parent 'Evented::Object';

use Evented::API::Module;
use Evented::API::Hax qw(set_symbol make_child package_unload);

our $VERSION = '1.7';

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
        mod_inc  => $inc,
        features => [],
        loaded   => []
    }, $class;
    
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
# returns the module names that loaded.
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
    my ($api, $mod_name, $dirs) = @_;
    return unless $mod_name;
    $api->_log("Loading $mod_name") unless $dirs;
    
    # we are in a load block.
    # we are not in the middle of loading this particular module.
    if ($api->{load_block} && !$dirs) {

        # make sure this module has not been attempted.
        if ($api->{load_block}{$mod_name}) {
            $api->_log("Load failed: $mod_name; Skipping already attempted module");
            return;
        }
    
        # add to attempted list.
        $api->{load_block}{$mod_name} = 1;
        
    }
    
    # check here if the module is loaded already.
    if ($api->module_loaded($mod_name)) {
        $api->_log("Load failed: $mod_name; Module already loaded");
        return;
    }
    
    # if there is no list of search directories, we have not attempted any loading.
    if (!$dirs) {
        return $api->load_module($mod_name, [ @{ $api->{mod_inc} } ]); # to prevent modification
    }
    
    # otherwise, we are searching the next directory in the list.
    my $search_dir = shift @$dirs;
    
    # already checked every search directory.
    if (!defined $search_dir) {
        $api->_log("Load failed: $mod_name; Module not found in any search directories");
        return;
    }
    
    $api->_log("Searching for module: $mod_name; $search_dir/");
    
    # module does not exist in this search directory.
    # try the next search directory.
    my $mod_name_file  = $mod_name; $mod_name_file =~ s/::/\//g;
    my $mod_last_name  = pop @{ [ split '/', $mod_name_file ] };
    my $mod_dir        = "$search_dir/$mod_name_file.module";
    if (!-d $mod_dir) {
        return $api->load_module($mod_name, $dirs);
    }
    
    # we located the module directory.
    # now we must ensure all required files are present.
    foreach my $file ("$mod_last_name.pm") {
        next if -f "$mod_dir/$file";
        $api->_log("Load failed: $mod_name; Mandatory file '$file' not present");
        return;
    }
    
    # fetch module information.
    my $info = $api->_get_module_info($mod_name, $mod_dir, $mod_last_name);
    return if not defined $info;
    
    my $pkg = $info->{package};
   
    # load required modules here.
    # FIXME: if these are loaded, then the module fails later, these remain loaded.
    $api->_load_module_requirements($info);
        
    # make the package a child of Evented::API::Module.
    make_child($pkg, 'Evented::API::Module'); 
    
    # create the module object.
    $info->{name}{last} = $mod_last_name;
    my $mod = $pkg->new(%$info);
    push @{ $api->{loaded} }, $mod;
    
    # hold a weak reference to the API engine.
    weaken($mod->{api} = $api);
    
    # export API Engine and module objects.
    set_symbol($pkg, {
        '$api'      => $api,
        '$mod'      => $mod,
        '$VERSION'  => $info->{version}
    });
        
    # load the module.
    $api->_log("Evaluating main package: $mod_name");
    my $return = do "$mod_dir/$mod_last_name.pm";
    
    # probably an error, or the module just didn't return $mod.
    if (!$return || $return != $mod) {
        $api->_log("Load failed: $mod_name; ".($@ || 'Package did not return module object'));
        @{ $api->{loaded} } = grep { $_ != $mod } @{ $api->{loaded} };
        package_unload($pkg);
        return;
    }
    
    # make engine listener of module.
    $mod->add_listener($api, 'module');
    
    # fire module initialize. if the fire was stopped, give up.
    if (my $stopper = $mod->fire_event('init')->stopper) {
        $api->_log("Load failed: $mod_name; Initialization canceled by '$stopper'");
        @{ $api->{loaded} } = grep { $_ != $mod } @{ $api->{loaded} };
        package_unload($pkg);
        return;
    }
    
    $api->_log("Loaded $mod_name successfully");
    return $mod_name;
}

# loads the modules a module depends on.
sub _load_module_requirements {
    my ($api, $info) = @_;
    
    # module does not depend on any other modules.
    my $mods = $info->{depends}{modules};
    return unless $mods;
    $info->{depends}{modules} = [$mods] if ref $mods ne 'ARRAY';
    
    foreach my $mod_name (@{ $info->{depends}{modules} }) {
    
        # dependency already loaded.
        if ($api->module_loaded($mod_name)) {
            $api->_log("Requirements of $$info{name}{full}; Skipping already loaded dependency");
            next;
        }
        
        # prevent endless loops.
        if ($info->{name}{full} eq $mod_name) {
            $api->_log("Requirements of $$info{name}{full}; Module depends on itself");
            next;
        }
        
        # load the dependency.
        $api->_log("Requirements of $$info{name}{full}; Loading dependency $mod_name");
        $api->load_module($mod_name);
        
    }
}

# fetch module information.
sub _get_module_info {
    my ($api, $mod_name, $mod_dir, $mod_last_name) = @_;
    my $json = JSON->new();
    
    # try reading module JSON file.
    my $info = $api->_slurp(undef, $mod_name, "$mod_dir/$mod_last_name.json");

    # no file - start with an empty hash.
    unless (defined $info) {
        $info = {};
    }
  
    # parse JSON.
    elsif (not $info = eval { $json->decode($info) }) {
        $api->_log("Load failed: $mod_name; JSON parsing of module info failed: $@");
        return;
    }
    
    # JSON was valid. now let's check the modified times.
    else {
        my $pkg_modified = (stat "$mod_dir/$mod_last_name.pm"  )[9];
        my $man_modified = (stat "$mod_dir/$mod_last_name.json")[9];
        
        # the manifest file is more recent or equal to the package file.
        # the JSON info is therefore up-to-date
        if ($man_modified >= $pkg_modified) {
            return $info;
        }
        
    }

    # try reading comments.
    open my $fh, '<', "$mod_dir/$mod_last_name.pm"
    or $api->_log("Load failed: $mod_name; Could not open file: $!") and return;
    
    # parse for variables.
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
                    $api->_log("Load failed: $mod_name; Evaluating '\@$var_name' failed: $@");
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
    
    # write JSON information.
    if ($info) {
        my $info_json = $json->pretty->encode($info);
        
        open my $fh, '>', "$mod_dir/$mod_last_name.json" or
         $api->_log("JSON warning: $mod_name; Could not write module JSON information")
         and return;
        
        $fh->write($info_json);
        close $fh;
        $api->_log("JSON: $mod_name; Updated module information file");
    }
    
    # check for required module info values.
    $info->{name} = { full => $info->{name} } if !ref $info->{name};
    foreach my $require (
        #[ 'name',   'short'   ],
        #[ 'name',   'full'    ],
        #[ 'name',   'package' ],
        [ 'name'        ],
        [ 'package'     ],
        [ 'version'     ]
    ) {
        my ($h, $n) = ($info, '');
        while (my $next = shift @$require) {
            $n .= "$h.";
            $h  = $h->{$next};
        }
        next if defined $h;
        
        # not present.
        chop $n;
        $api->_log("Load failed: $mod_name; Mandatory info '$n' not present");
        return;
        
    }
    
    return $info;
}

#########################
### UNLOADING MODULES ###
#########################

# unload a module.
sub unload_module {
    my ($api, $mod) = @_;
    
    # check if any loaded modules are dependent on this one.
    if (my @dependents = $mod->dependents) {
        @dependents = grep { $_->name } @dependents;
        $mod->_log("Can't unload; dependent modules: @dependents");
        return;
    }
        
    # fire module void. if the fire was stopped, give up.
    if (my $stopper = $mod->fire_event('void')->stopper) {
        $api->_log("Can't unload; canceled by '$stopper'");
        return;
    }
    
    # unregister all managed event callbacks.
    $mod->_delete_managed_events();
    
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

my %syntax = (

    mod_load_begn => '%s(%s): INITIATING MODULE LOAD',
    mod_load_info => '%s(%s): %s',
    mod_load_warn => '%s(%s): Warning: %s',
    mod_load_fail => '%s(%s): *** FAILED TO LOAD *** %s',
    mod_load_comp => '%s(%s): MODULE LOADED SUCCESSFULLY',

    mod_unload_begn => '%s(%s): PREPARING TO UNLOAD',
    mod_unload_info => '%s(%s): %s',
    mod_unload_fail => '%s(%s): failed to unload: %s'

);

# API log.
sub _log {
    my $api = shift;
    return $api->fire_event(log => shift);
}

# read contents of file.
sub _slurp {
    my ($api, $log_type, $mod_name, $file_name) = @_;
    
    # open file.
    my $fh;
    if (!open $fh, '<', $file_name) {
        return unless $log_type;
        $api->_log("$file_name could not be opened for reading");
        return;
    }
    
    # read and close file.
    local $/ = undef;
    my $data = <$fh>;
    close $fh;
    
    return $data;
}

1;
