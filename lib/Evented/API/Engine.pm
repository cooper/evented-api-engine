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
use Evented::API::Hax;

our $VERSION = '0.5';

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

#########################
### MODULE MANAGEMENT ###
#########################

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
    
    # module does not exist in this search directory.
    # try the next search directory.
    my $mod_name_file  = $mod_name; $mod_name_file =~ s/::/\//g;
    my $short_mod_file = pop @{ [ split '/', $mod_name_file ] };
    my $mod_dir        = "$search_dir/$mod_name_file.module";
    if (!-d $mod_dir) {
        return $api->load_module($mod_name, $dirs);
    }
    
    # we located the module directory.
    # now we must ensure all required files are present.
    foreach my $file ("$short_mod_file.json", "$short_mod_file.pm") {
        next if -f "$mod_dir/$file";
        $api->_log('mod_load_fail', $mod_name, "Mandatory file '$file' not present");
        return;
    }
    
    # read module.json.
    # FIXME: 'or return' ends loading unexpectedly if $short_mod_file.json is an empty file.
    my $info = $api->_slurp('mod_load_fail', $mod_name, "$mod_dir/$short_mod_file.json") or return;
    if (not $info = eval { decode_json($info) }) {
        $api->_log('mod_load_fail', $mod_name, "JSON parsing of module info failed: $@");
        return;
    }
    
    # TODO: load the module.
    
    # TODO: add global API module methods.
    
    
    $api->_log('mod_load_comp', $mod_name);
    return $mod_name;
}

# unload a module.
sub unload_module {
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
sub add_methods {
}

# add new methods to all modules in the API Engine.
sub add_module_methods {
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
    given ($type) {
        when ('mod_load_begn') { $syn = "%s(%s): BEGINNING MODULE LOAD"             }
        when ('mod_load_info') { $syn = "%s(%s): %s"                                }
        when ('mod_load_fail') { $syn = "%s(%s): *** FAILED TO LOAD *** %s"         }
        when ('mod_load_comp') { $syn = "%s(%s): MODULE LOADED SUCCESSFULLY"        }
    }
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
