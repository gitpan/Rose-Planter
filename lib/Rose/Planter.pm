package Rose::Planter;

use warnings;
use strict;

=head1 NAME

Rose::Planter - Keep track of classes created with Rose::DB::Object::Loader.

=cut

our $VERSION = '0.32';

=head1 SYNOPSIS

In My/Objects.pm :

    package My::Objects;

    use Rose::Planter
        loader_params => {
            class_prefix => "My::Object",
            db_class     => "My::DB",
        },
        nested_tables => {
            foo => [ qw(params) ]
        },
        convention_manager_params => {};

In plant.pl :

    #!/usr/bin/env perl

    Rose::Planter->plant("My::Objects" => "My/Objects/autolib");

In another file :

    use My::Objects;

    my $class = Rose::Planter->find_class("my_table");
    my $object = Rose::Planter->find_object("my_table","my_key1","my_key2");


=head1 DESCRIPTION

This is a thin layer above L<Rose::DB::Object::Loader> for keeping
track of and managing classes which are created based on a database
schema.  It will transparently either query the database using
L<Rose::DB::Object::Loader> or use an auto-generated class
hierarchy.

This module works well with L<Module::Build::Database> and
L<Clustericious> to create a simple RESTful service based on
a database schema.  It can be used to provide a common base
class, conventions, and settings for a collection of services,
as well as describe which tables within a schema should be
coupled with other tables during CRUD operations.

By default the loader is told that the base_class should be
L<Rose::Planter::Soil>.  You can send "base_classes" or
just "base_class" as loader_params to changes this.

nested_tables will cause find_object to automatically join tables
connected to the primary table with a many-to-one relationship.

=head1 FUNCTIONS

=cut

use Rose::DB::Object::Loader;
use Rose::Planter::ConventionManager;
use Rose::Planter::Gardener;
use List::MoreUtils qw/mesh/;
use File::Path qw/mkpath/;
use File::Slurp qw/slurp/;
use Module::Find;
use strict;
use warnings;

our %table2Class;    # mapping from table name to class name.
our %deftable2Class; # map for prefix of tables ending in _def to class name.
our %plural2Class;   # map plurals of tables to manager classes
our %are_planting;   # classes we are planting right now
{
my $_logfp;
sub _trace {
    # Hook for tracing at compile time
    return unless $ENV{ROSE_PLANTER_DEBUG};
    my $msg = shift;
    unless ($_logfp) {
        $_logfp = IO::File->new(">>/tmp/rose.log");
    }
    print $_logfp "$msg\n";
}
}

sub import {
    my ($class, %p) = @_;
    return unless %p && keys %p;
    my $from = caller;
    return $class->_read_classes(%p, seed => $from) || $class->_write_classes(%p, seed => $from) || $class->_setup_classes(%p);
}

sub _class2path {
    my $cl = shift;
    $cl =~ s[::][/]g;
    return $cl;
}

sub _read_classes {
    my ($class, %params) = @_;
    my $seed = $params{seed};
    return 0 if $seed && $are_planting{$seed};
    my $seed_dir = _class2path($seed).'.pm';
    my $inc_dir = $INC{$seed_dir} or return 0;  # e.g. testing
    my ($abs_seed_dir) = $inc_dir=~ m{^(.*)/$seed_dir$};

    my $prefix = $params{loader_params}{class_prefix} ;
    my $autolib = $seed. '::autolib';
    my $autodir = join '/', $abs_seed_dir, _class2path($autolib);
    _trace "Looking for $autolib in $autodir";
    unshift @INC, $autodir;
    local $SIG{__WARN__} = sub {
        return if $_[0] =~ /^subroutine.*redefined/i;
        warn @_;
    };
    my @used = useall $autolib;
    _trace "used $_" for @used;
    shift @INC;
    unless (@used) {
        warn "# No autolib found ($autolib), try :\n";
        warn "# Rose::Planter->plant(q[$seed] => q[$autodir])\n";
        return 0;
    };
    do { s/${autolib}:://; } for @used;
    $class->_setup_classes(made => \@used, %params);
    return 1;
}

sub _sow {
    my $class = shift;
    my $seed = shift;
    my $dir   = shift;
    $are_planting{$seed} = $dir;
}

=head2 plant

    Rose::Planter->plant($class => $dir)

Write a class hierarchy to disk.

=cut

sub plant {
    my $class = shift;
    my $seed = shift;
    my $dir = shift;
    $class->_sow($seed => $dir);
    if ($INC{_class2path($seed).'.pm'}) {
        die "Cannot plant $seed since it has already been loaded.";
    }
    eval "use $seed";
    die $@ if $@;
}

sub _add_postamble {
    my ($db_class, $met,$manager) = @_;
    my $want = ($manager || $met->class);
    my $file = $want;
    $file =~ s[::][/]g;
    $file .= ".pm";
    my ($found) = map "$_/$file", grep { -e "$_/$file" } @INC;
    my $setdb = $db_class && !$manager ? "\n sub init_db { $db_class->new() };\n" : "";
    if ($found) {
        _trace "# adding functions from $found";
        return join "", $setdb,  "# EXTRAS LOADED FROM $found : \n", slurp $found;
    }
    return "$setdb\n# NOTHING LOADED FOR $want";
}

sub _write_classes {
    my $class = shift;
    my %params = @_;
    my $dir;
    my $seed = $params{seed} or die "no seed";
    return 0 unless $dir = $are_planting{$seed};
    mkpath $dir;
    warn "# writing classes to $dir\n";
    my $db_class = $params{loader_params}{db_class};
    $params{loader_params}{module_dir} = $dir;
    $params{loader_params}{module_postamble} = sub { _add_postamble($db_class, @_) };
    $class->_setup_classes(%params, make_modules => 1);
    return 1;
}

sub _setup_classes {
    my $class = shift;
    my %params = @_;

    my %loader_params = %{ $params{loader_params} || {} };

    unless ($loader_params{base_class} || $loader_params{base_classes}) {
        $loader_params{base_class} = "Rose::Planter::Soil";
    }

    unless ($loader_params{manager_base_class} || $loader_params{manager_base_classes}) {
        $loader_params{manager_base_class} = "Rose::Planter::Gardener";
    }

    my $loader = Rose::DB::Object::Loader->new(
        warn_on_missing_primary_key => 1,
        convention_manager          => "Rose::Planter::ConventionManager",
        %loader_params
    );
    my $method = $params{make_modules} ? "make_modules" : "make_classes";
    my @made = $params{made} ? @{ $params{made} } : $loader->$method; # include_tables => ...
    die "did not make any classes" unless @made > 0;
    # Keep track of what we made
    for my $made (@made) {
        if ( $made->can("meta") ) {
            _trace "Made object class $made";
            my $table = $made->meta->table;
            warn "replacing $table ($table2Class{$table}) with $made"
              if $table2Class{$table} && $table2Class{$table} ne $made;
            $table2Class{$table} = $made;
            if ( $table =~ /^(.*)_def$/ ) {
                warn "replacing $1 ($table2Class{$1}) with $made"
                  if $table2Class{$1} && $table2Class{$1} ne $made;
                $deftable2Class{$1} = $made;
            }
        }
        if ( $made->can("get_objects") ) {
            _trace "Made manager class $made";
            my $object_class = $made->object_class;
            my $table        = $object_class->meta->table;
            $table =~ s/_def//;
            my $plural = Rose::Planter::ConventionManager->new()->singular_to_plural($table);
            $plural2Class{$plural} = $made;
        }
        # Load any extra functions, too.
        unless ($method eq 'make_modules') {
            eval "use $made";
            die "Errors using $made : $@" if $@ && $@ !~ /Can't locate/;
        }
    }

    my %nested_tables = %{ $params{nested_tables} || {} };
    for my $t (keys %nested_tables) {
        my $found =  $class->find_class($t) or die "could not find class for base table $t";
        $found->nested_tables($nested_tables{$t});
    }
}

=head2 tables

Return a list of all tables.

=cut

sub tables {
    return (keys %table2Class, keys %deftable2Class);
}

=head2 regex_for_tables

Create a regex that matches all the tables.

=cut

sub regex_for_tables {
    my $self = shift;
    # the reverse sort is necessary so that tables which
    # are prefixes to others match.  e.g. app, appgroup
    # see https://github.com/kraih/mojo/issues/183
    my $re = join '|', reverse sort $self->tables;
    return qr[$re];
}

=head2 plurals

Return a list of all plurals.

=cut

sub plurals {
    return keys %plural2Class;
}

=head2 regex_for_plurals

Create a regex that matches all the plurals.

=cut

sub regex_for_plurals {
    my $self = shift;
    my $re = join '|', reverse sort $self->plurals;
    return qr[$re];
}

=head2 find_class

Given the name of a database table, return the object class associated
with it.  e.g.

    Rose::Planter->find_class("app");

If the table name ends in _def, the prefix may be used, e.g
these are equivalent :

    Rose::Planter->find_class("esdt_def");
    Rose::Planter->find_class("esdt");

Also, given the plural of the name of a database table, return the
manager class associated with it.

    Rose::Planter->find_class("esdts");
    Rose::Planter->find_class("apps");

=cut

sub find_class {
    my $class = shift;
    my $table = shift;
    return $table2Class{$table} || $deftable2Class{$table} || $plural2Class{$table};
}

=head2 find_object

Given a table and a primary or other unique key(s), find a load an object.

Return false if there is no object matching that key.

=cut

sub find_object {
    my $package = shift;
    my $table  = shift;
    my @keys   = @_;

    my $object_class = Rose::Planter->find_class($table) or die "could not find class for $table";
    return unless $object_class->can("meta");

    foreach my $keycols ([$object_class->meta->primary_key_column_names],
                         $object_class->meta->unique_keys_column_names) {
        next unless @keys == @$keycols;
        my $object = $object_class->new( mesh @$keycols, @keys );
        return $object if $object->load(speculative => 1,
                                        with => $object_class->nested_tables);
    }

    return;
}

=head1 NOTES

This is a beta release.  The API is subject to change without notice.

=head1 AUTHORS

Marty Brandon

Brian Duggan

Graham Ollis

Curt Tilmes

=head1 BUGS

Currently only really used/tested against postgres.

=cut

1;
