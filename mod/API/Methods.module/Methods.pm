# Copyright (c) 2013 Mitchell Cooper
#
# @version:         Evented::API::Engine->VERSION
# @name.short:      "API::Methods"
# @name.full:       "API::Methods"
# @name.package:    "Evented::API::Methods"
#
# @author.name:     "Mitchell Cooper"
# @author.website:  "https://github.com/cooper"
#
package Evented::API::Methods;

use warnings;
use strict;

our ($api, $mod);

sub init {
    my $fire = shift;
    
    # add methods.
    *API::Module::register_engine_method = *register_engine_method;
    *API::Module::register_module_method = *register_module_method;
    
    # XXX: these handlers will not be deleted automatically.
    $api->register_event('module.void' => \&any_void,
        name => 'api.engine.methods.any.void'
    );
    
}

sub void {
    my $fire = shift;
    undef *API::Module::register_engine_method;
    undef *API::Module::register_module_method;
}

sub any_void {
    my $fire = shift;
    my $void = $fire->object;
    my $e_methods = $void->retrieve('engine_methods') || {};
    my $m_methods = $void->retrieve('module_methods') || {};
    
    # delete API engine methods.
    foreach my 
    
}

# register a method to API Engine.
sub register_engine_method {
    my ($mod, $name, $code, %opts) = @_;
    
}

# register a method to API modules.
sub register_module_method {
    my ($mod, $name, $code, %opts) = @_;
        
}

$mod;
