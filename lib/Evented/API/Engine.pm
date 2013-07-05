# Copyright (c) 2013 Mitchell Cooper
# the API Engine is in charge of loading and unloading modules.
# It also handles dependencies and feature availability.
package Evented::API::Engine;

use warnings;
use strict;
use 5.010;

use Carp;
use JSON qw(decode_json);

use Evented::Object;
use parent 'Evented::Object';

use Evented::API::Module;
use Evented::API::Hax qw(set_symbol make_child export_code);

our $VERSION = '1.1';

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
    
    # several search directories.
    my $inc;
    if (defined $opts{mod_inc} && ref $opts{mod_inc} eq 'ARRAY') { $inc = $opts{mod_inc} }
    
    elsif (defined $opts{mod_inc}) { $inc = [ $opts{mod_inc} ] } # single search directory
    else { $inc = ['.', 'mod'] }                                 # no search directories
    
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
    $api->_log('mod_load_begn', $mod_name) unless $dirs;
    
    # we are in a load block.
    # we are not in the middle of loading this particular module.
    if ($api->{load_block} && !$dirs) {

        # make sure this module has not been attempted.
        if ($api->{load_block}{$mod_name}) {
            $api->_log('mod_load_fail', $mod_name, 'Skipping already attempted module');
            return;
        }
    
        # add to attempted list.
        $api->{load_block}{$mod_name} = 1;
        
    }
    
    # check here if the module is loaded already.
    if ($api->module_loaded($mod_name)) {
        $api->_log('mod_load_fail', $mod_name, 'Module already loaded');
        return;
    }
    
    # if there is no list of search directories, we have not attempted any loading.
    if (!$dirs) {
        return $api->load_module($mod_name, [ @{ $api->{mod_inc} } ]);
    }
    
    # otherwise, we are searching the next directory in the list.
    my $search_dir = shift @$dirs;
    
    # already checked every search directory.
    if (!defined $search_dir) {
        $api->_log('mod_load_fail', $mod_name, 'Module not found in any search directories');
        return;
    }
    
    $api->_log('mod_load_info', $mod_name, "Searching for module in: $search_dir/");
    
    # TODO: add support for __DATA__ JSON and single-file modules.
    # rethink: how about wikifier-style variables?
    
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
    foreach my $file ("$mod_last_name.json", "$mod_last_name.pm") {
        next if -f "$mod_dir/$file";
        $api->_log('mod_load_fail', $mod_name, "Mandatory file '$file' not present");
        return;
    }
    
    # fetch module information.
    my $info = $api->_get_module_info($mod_name, $mod_dir, $mod_last_name);
    return if not defined $info;
    
    my $pkg = $info->{name}{package};
   
    # load required modules here.
    $api->_load_module_requirements($info);
    
    # TODO: add global API module methods here.
    
    # make the package a child of Evented::API::Module.
    make_child($pkg, 'Evented::API::Module'); 
    
    # create the module object.
    $info->{name}{last} = $mod_last_name;
    my $mod = $pkg->new(%$info);
    push @{ $api->{loaded} }, $mod;
    
    # export API Engine and module objects.
    set_symbol($pkg, {
        '$api'      => $api,
        '$mod'      => $mod,
        '$VERSION'  => $info->{version}
    });
        
    # load the module.
    $api->_log('mod_load_info', $mod_name, 'Evaluating main package');
    my $return = do "$mod_dir/$mod_last_name.pm";
    
    # probably an error, or the module just didn't return $mod.
    if (!$return || $return != $mod) {
        $api->_log('mod_load_fail', $mod_name, $@ ? $@ : 'Package did not return module object');
        @{ $api->{loaded} } = grep { $_ != $mod } @{ $api->{loaded} };
        # hax::package_unload();
        return;
    }
    
    # fire module initialize. if the fire was stopped, give up.
    if (my $stopper = $mod->fire_event('initialize')->stopper) {
        $api->_log('mod_load_fail', $mod_name, "Initialization canceled by '$stopper'");
        @{ $api->{loaded} } = grep { $_ != $mod } @{ $api->{loaded} };
        # hax::package_unload();
        return;
    }
    
    $api->_log('mod_load_comp', $mod_name);
    return $mod_name;
}

# loads the modules a module depends on.
sub _load_module_requirements {
    my ($api, $info) = @_;
    
    # module does not depend on any other modules.
    return unless $info->{depends}{modules};
    return unless ref $info->{depends}{modules} eq 'ARRAY';
    
    foreach my $mod_name (@{ $info->{depends}{modules} }) {
    
        # dependency already loaded.
        if ($api->module_loaded($mod_name)) {
            $api->_log('mod_load_info', $mod_name, 'Skipping already loaded dependency');
            next;
        }
        
        # prevent endless loops.
        if ($info->{name}{full} eq $mod_name) {
            $api->_log('mod_load_info', $mod_name, 'MODULE DEPENDS ON ITSELF?!?!');
            next;
        }
        
        # load the dependency.
        $api->_log('mod_load_info', $mod_name, 'Loading dependency of '.$info->{name}{full});
        $api->load_module($mod_name);
        
    }
}

# fetch module information.
sub _get_module_info {
    my ($api, $mod_name, $mod_dir, $mod_last_name) = @_;
 
    # try reading module JSON file.
    my $info = $api->_slurp('mod_load_fail', $mod_name, "$mod_dir/$mod_last_name.json");

    # no file - start with an empty hash.
    unless (defined $info) {
        $info = {};
    }
  
    # parse JSON.
    elsif (not $info = eval { decode_json($info) }) {
        $api->_log('mod_load_fail', $mod_name, "JSON parsing of module info failed: $@");
        return;
    }

    # try reading comments.
    open my $fh, '<', "$mod_dir/$mod_last_name.pm"
    or $api->_log('mod_load_fail', $mod_name, "Could not open file: $!") and return;
    
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
                    $api->_log('mod_load_fail', $mod_name, "Evaluating '\@$var_name' failed: $@");
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
        my $info_json = JSON->new->pretty->encode($info);
        
        open my $fh, '>', "$mod_dir/$mod_last_name.json" or
         $api->_log('mod_load_warn', $mod_name, 'Could not write module JSON information')
         and return;
        
        $fh->write($info_json);
        close $fh;
        $api->_log('mod_load_info', $mod_name, 'Updated module information file');
    }
    
    # check for required module info values.
    foreach my $require (
        [   'name.short',   $info->{name}{short}    ],
        [   'name.full',    $info->{name}{full}     ],
        [   'name.package', $info->{name}{package}  ],
        [   'version',      $info->{version}        ]
    ) {
        next if defined $require->[1];
        $api->_log('mod_load_fail', $mod_name, "Mandatory info '$$require[0]' not present");
        return;
    }
    
    return $info;
}

#########################
### UNLOADING MODULES ###
#########################

# unload a module.
sub unload_module {
    # TODO: check if any loaded modules are dependent on this one
    # TODO: remove methods registered by this module.
    # TODO: built in callback will call 'void' in the module package.
}

########################
### FETCHING MODULES ###
########################

# returns the module object of a full module name.
sub get_module {
    my ($api, $mod_name) = @_;
    foreach (@{ $api->{loaded} }) {
        return $_ if $_->{name}{full} eq $mod_name;
    }
    return;
}

# returns the module object associated with a package.
sub package_to_module {
    my ($api, $package) = @_;
    foreach (@{ $api->{loaded} }) {
        return $_ if $_->{name}{package} eq $package;
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

#######################
### DYNAMIC METHODS ###
#######################

# add new methods to the API Engine.
sub add_method {
    my ($api, $method_name, $method_code) = @_;
    
    # is this a module calling?
    if (my $mod = $api->package_to_module(caller)) {
        $mod->{global_engine_methods} ||= [];
        push @{ $mod->{global_engine_methods} }, $method_name;
    }
    
    export_code(__PACKAGE__, $method_name, $method_code);
}

# add new methods to all modules in the API Engine.
sub add_module_method {
    my ($api, $method_name, $method_code) = @_;
    
    # is this a module calling?
    if (my $mod = $api->package_to_module(caller)) {
        $mod->{global_module_methods} ||= [];
        push @{ $mod->{global_api_methods} }, $method_name;
    }
    
    export_code('Evented::API::Module', $method_name, $method_code);
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

################
### INTERNAL ###
################

# API log.
sub _log {
    my ($api, $type, $syn) = (shift, shift);
    my %syntax = (
        mod_load_begn => "%s(%s): BEGINNING MODULE LOAD",
        mod_load_info => "%s(%s): %s",
        mod_load_warn => "%s(%s): Warning: %s",
        mod_load_fail => "%s(%s): *** FAILED TO LOAD *** %s",
        mod_load_comp => "%s(%s): MODULE LOADED SUCCESSFULLY"
    );
    $syn = $syntax{$type};
    return unless defined $syn;
    
    my $sub = (caller 1)[3];
    $sub    =~ s/Evented::API:://;
    my $msg = sprintf $syn, $sub, @_;
    
    $api->fire_event(log => $msg);
    return;
}

# read contents of file.
sub _slurp {
    my ($api, $log_type, $mod_name, $file_name) = @_;
    
    # open file.
    my $fh;
    if (!open $fh, '<', $file_name) {
        $api->_log($log_type, $mod_name, "$file_name could not be opened for reading");
        return;
    }
    
    # read and close file.
    local $/ = undef;
    my $data = <$fh>;
    close $fh;
    
    return $data;
}

1;
