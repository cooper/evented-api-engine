# Copyright (c) 2013 Mitchell Cooper
# the API Engine is in charge of loading and unloading modules.
# It also handles dependencies and feature availability.
package Evented::API::Engine;

use warnings;
use strict;
use 5.010;

use Carp;

use Evented::Object;
use parent 'Evented::Object';

use Evented::API::Module;
use Evented::API::Hax;

our $VERSION = '0.2';

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
    
    # Determine the include directories.
    
    my $inc;
    
    # mod_inc is present and an array reference.
    if (defined $opts{mod_inc} && ref $opts{mod_inc} eq 'ARRAY') { $inc = $opts{mod_inc} }
    
    # mod_inc is present but not an array reference.
    elsif (defined $opts{mod_inc}) { $inc = [ $opts{mod_inc} ] }
    
    # nothing; use default include directories.
    else { $inc = ['.', 'mod'] }
    
    # create the API Engine.
    my $api = bless {
        mod_inc => $inc
    }, $class;
    
    $api->_configure_api();
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
# returns the number of modules that loaded successfully.
sub load_modules_initially {
    my ($api, @mod_names) = @_;
    $api->{load_block} = { in_block => 1 };
    
    # load each module from within a load block.
    my @results;
    push @results, $api->load_module($_) foreach @mod_names;
    
    delete $api->{load_block};
    return scalar grep { $_ } @results;
}

# load a module.
sub load_module {
    my ($api, $mod_name) = @_;
    
    # we are in a load block.
    if ($api->{load_block}) {

        # make sure this module has not been attempted.
        if ($api->{load_block}{$mod_name}) {
            carp "Skipping '$mod_name' because it was already attempted.";
            return;
        }
    
        # add to attempted list.
        $api->{load_block}{$mod_name} = 1;
        
    }
    
    # TODO: load the module.
    
    return 1;
}

# unload a module.
sub unload_module {
}

####################
### DATA STORAGE ###
####################

# store a piece of data specific to this API Engine.
sub store {
}

# fetch a piece of data specific to this API Engine.
sub retrieve {
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

sub add_feature {
}

sub remove_feature {
}

sub has_feature {
}

1;
