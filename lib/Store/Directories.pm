package Store::Directories;

use 5.006;
use strict;
use warnings;

our $VERSION = '0.1';

=head1 NAME

Store::Directories - Manage a key/value store of directories with locking
capabilities

=head1 SYNOPSIS

    use Store::Directories;

    # Create a new store at given directory
    # (or adopt one that is already there)
    my $store = Store::Directories->init("path/to/store/")

    # (In this example, we create a new directory containing a text file
    # and then atomically increment the value written in the file)

    my $value = 1;

    # Get a directory with the key 'foo' in the store,
    # creating it if it doesn't exist yet
    my $lock;
    my $dir = $store->get_or_add('foo' {

        # as an option, we can provide a subroutine to use to
        # initialize the directory contents if we create it
        # (but if the directory already exists, this won't be called)
        init => sub {
            my $dir = shift;
            open(my $fh, '>', "$dir/hello.txt") or die "could not open file: $!";
            print $fh $value;
            close $fh;
        }
    });

    {
        # Get an exclusive lock on the directory before reading/writing to it.
        # This ensure no other process is reading or modifying the directory
        # contents while we're working.
        my $lock = $store->lock_ex('foo');

        open(my $fh, '<', "$dir/hello.txt") or die "could not open file: $!";
        $value = <$fh>;
        open($fh, '>', "$dir/hello.txt")    or die "could not re-open file: $!";
        print $fh $value + 1;
        close $fh;

        # The lock is released once $lock is out-of-scope
    }


=head1 DESCRIPTION

L<Store::Directories> manages a key/value store of directories and allows
processes to assert shared (read-only) or exclusive (writable) locks on
those directories.

B<WARNING:> The guarantees around locking make the assumption that every
process is using this Distribution and playing by its rules.
Unrelated processes are free to ignore the rules and mess things up as
much as they like.

=cut

use Carp;
use Cwd qw(abs_path);
use File::Spec::Functions qw(catfile);
use File::Path qw(make_path remove_tree);
use Time::HiRes qw(sleep);
use File::Basename;

use DBI;
use Data::UUID;
use SQL::SplitStatement;
use IPC::System::Simple qw(system);

use Store::Directories::Lock qw(UN SH EX);

my $UUIDGEN = Data::UUID->new;

my $dir = dirname(__FILE__);
my $sql_schema = catfile($dir, qw(Directories store-directories-schema.sql));

########################
# PUBLIC INTERFACE
########################

=head1 PUBLIC METHODS

=over 4

=item * B<init> I<DIRECTORY>

Create and return a new L<Store::Directories> instance in the given directory.
Bookkeeping files and directory entries will be stored inside this directory.
If a L<Store::Directories> instance already exists in that directory,
then this will simply adopt the one that's there.
=cut
sub init {
    my $class = shift;
    my $dir   = shift;

    croak "Must specify a directory." unless $dir;
    $dir = abs_path $dir;
    make_path($dir) unless -d $dir;

    my $self = bless {
        dir         => $dir,
        dbfile      => catfile($dir, 'index.db')
    }, $class;

    my $index_exists = ( -f $self->{dbfile} );

    my $dbh = $self->_new_connection; # this creates the db files if
                                      # it doesn't exist yet

    # Init the index if we just created it
    _init_db($dbh) unless $index_exists;

    return $self;
}

=item * B<path>

Get the absolute path to this Store's directory.
=cut
sub path {
    my $self = shift;
    return $self->{dir};
}

=item * B<get_or_add> I<KEY>, I<{OPTIONS}>

Get the path to the directory referred to by C<KEY>, creating it if it doesn't
yet exist. Returns the absolute path to the directory.
C<OPTIONS> is a hashref that can contain the following options:

=over 4

=item * B<init> I<(subroutine ref)>

A subroutine used to initialize the directory in the event that it gets
created (although if the directory already exists when C<get_or_add> is called,
this won't be called). This is called with the absolute path to the directory
as the first, and only argument, and an exclusive lock is active on the
directory for the duration of the function. If the function dies, then the
entire call to C<get_or_add> will croak and the directory will not be created.
If this isn't specified, an empty directory is created. (B<default:> undef)

=item * B<lock_sh> I<(scalar ref)>

Create a shared lock to the directory, storing it in the value referenced by
this option. This works like calling the C<lock_sh> method, but eliminates
the possible race condition where another process can get a lock (or even
remove) the directory between creating it and calling C<lock_sh>. However, if
the directory already exists, this may block until the lock can be obtained.
(B<default:> undef)

=item * B<lock_ex> I<(scalar ref)>

Just like the C<lock_sh> option, but for an exclusive lock. If both options are
specified, only the exclusive lock is created and the shared lock is ignored.
(B<default:> undef)

=back

Example:

    my $lock;
    my $dir = $store->get_or_add('foobar' {
        init    => sub {
            my $dir = shift;
            # Initialize directory
        },
        lock_sh => \$lock
    });

B<NOTE:> Keys matching the pattern C</^__.*__$/> (that is, surrounded by
double-underscores) are reserved by L<Store::Directories> and cannot be used.
Currently, the only key like this is C<__LISTING__>, which is used internally
to lock the list of directories (so that they can't be removed or added).

=cut
sub get_or_add {
    my $self = shift;
    my $key  = shift;
    my $opts = shift // {};

    if ($key =~ /^__.*__$/) {
        croak "Keys of the pattern '__FOO__' are reserved by Store::Directories";
    }

    # Resolve lock_sh/ex options
    my $lockmode, my $lockref;
    if ($lockref = $opts->{lock_ex}) {
        croak "'lock_ex' must be a scalar ref." unless ref $lockref eq 'SCALAR';
        $lockmode = EX;
    }
    elsif ($lockref = $opts->{lock_sh}) {
        croak "'lock_sh' must be a scalar ref." unless ref $lockref eq 'SCALAR';
        $lockmode = SH;
    }
    else { $lockmode = UN }

    # The __LISTING__ lock ensures that directories cannot be added or removed
    # while we're wokring.
    my $listing_lock = $self->lock_ex('__LISTING__');

    # Get directory if it exists
    my $dbh = $self->_new_connection;
    my $sth = $dbh->prepare("SELECT dir FROM entry WHERE slug = ?");
    $sth->execute($key) or  croak "Failed to fetch entries: ".$dbh->errstr;
    my $entry = $sth->fetch;
    defined $dbh->err   and croak "Failed to fetch entries: ".$dbh->errstr;

    # If the directory exists already, we can return now
    if ($entry) {
        # Create a lock if the user requested one
        if ($lockmode) {
            $listing_lock->DESTROY;
            $$lockref = Store::Directories::Lock->new($self, $key, $lockmode);
        }
        return catfile($self->{dir}, $entry->[0]);
    }

    # The directory has to be created
    my $lock;
    my $dir;
    $self->_transaction($dbh, sub {
        $dir = $self->_add_directory($dbh, $key);

        if ($lockmode or defined $opts->{init}) {
            # If the user wanted a lock, create it here before releasing
            # the __LISTING__ lock.
            # (if we're going to call an init function, we need it to be
            # an exclusive lock first, regardless of what the user asked for)
            my $mode = defined $opts->{init} ? EX : $lockmode;
            Store::Directories::Lock::_add_lock_noblock($dbh, $key, EX);
            $lock = Store::Directories::Lock->_new_raw($self, $key, $$, EX);
        }
    });
    $listing_lock->DESTROY;

    # Use init function to create directory contents;
    if ($opts->{init}) {
        eval {
            use sigtrap qw(die normal-signals);
            die "'init' must be a subroutine ref" unless ref $opts->{init} eq 'CODE';
            $opts->{init}->($dir);
            1;
        } or do {
            # Cleanup if callback failed
            my $errmsg = "Function call to initialize directory died. $@";
            {
                my $temp_lock = $self->lock_ex('__LISTING__');
                $self->_remove_directory_from_db($dbh, $key);
            }
            eval {
                $self->_remove_directory_from_disk(basename($dir));
                1;
            } or carp "Failed to clean up directory, but it has been ".
                      "removed from the index";
            croak $errmsg;
        };
    }

    if ($lockmode == SH && $lock->{mode} == EX) {
        # If the user wanted a shared lock, but we made an exclusive one
        # (because of the init function), then we need to downgrade it first
        Store::Directories::Lock::_add_lock_noblock($dbh, $key, SH);
        $lock->{mode} = SH;
    }
    $$lockref = $lock if $lockmode;

    return $dir;
}

=item * B<lock_sh> I<KEY>

Create and return a new I<shared> lock for the given key. This asserts that
no other process can modify the corresponding entry until this lock goes
out-of-scope.

This blocks until the lock can be obtained. So it will wait for any processes
that already have an exclusive lock on this key to release their locks before
returning.

This will croak if this process already has a lock (either kind) on this key,
or if the key does not exist in the store.
=cut
sub lock_sh {
    my $self = shift;
    my $key  = shift;
    return Store::Directories::Lock->new($self, $key, SH);
}

=item * B<lock_ex> I<KEY>

Create and return a new I<exclusive> lock for the given key. This asserts that
no other process can read the corresponding entry until this lock goes
out-of-scope.

This blocks until the lock can be obtained. So it will wait for any processes
that have locks on this key to release them before returning.

This will croak if this process already has a lock (either kind) on this key,
or if the key does not exist in the store.
=cut
sub lock_ex {
    my $self = shift;
    my $key  = shift;
    return Store::Directories::Lock->new($self, $key, EX);
}

=item * B<remove> I<KEY> I<[SUB]>

Remove the directory with the given key from the store. You I<MUST> have an
exclusive lock already on the directory before calling this. C<SUB> is a
subroutine ref which, if specified, will be called immediately before deleting
the directory. C<SUB> is called with the path to the directory as the first and
only argument.

If an error occurs removing the directory from disk, (from C<SUB> failing,
or otherwise), then the directory will still be removed from the store's index
and a warning will be given as the directory still on disk may be in a
degraded state.
=cut
sub remove {
    my ($self, $key, $callback) = @_;
    my $dbh = $self->_new_connection;

    my $listing_lock = $self->lock_ex('__LISTING__');

    # First check that the directory exists
    my $sth = $dbh->prepare("SELECT dir FROM entry WHERE slug = ?");
    $sth->execute($key) or  croak "Failed to fetch entries: ".$dbh->errstr;
    my $entry = $sth->fetch;
    defined $dbh->err   and croak "Failed to fetch entries: ".$dbh->errstr;

    unless ($entry) {
        carp "Asked to remove directory with key '$key', but it ".
             "does not exist.";
        return 1;
    }
    my $dir  = $entry->[0];
    my $path = abs_path( catfile($self->{dir}, $dir) );

    # Check that we have an exclusive lock
    my $current_lock = Store::Directories::Lock::_get_lock_mode($dbh, $key);
    unless ($current_lock == EX) {
        croak "Must have exclusive lock on directory '$key' before ".
              "attempting to remove it!";
    }

    # Remove from database
    $self->_remove_directory_from_db($dbh, $key);
    $listing_lock->DESTROY;

    # Attempt to remove directory from disk
    eval {
        if ($callback) {
            die "'SUB' must be a subroutine ref" unless ref $callback eq 'CODE';
            $callback->($path);
        }
        $self->_remove_directory_from_disk($dir);
        1;
    } or carp "Failed to totally delete directory '$key' ($dir), but it has ".
              "been removed from the index.";

    1;
}

=item * B<get_locks> I<KEY>

Returns a hashref listing all of the current locks for the directory
with the given C<KEY>. Each key in the hash is the PID of a process and each
corresponding value is true/false indicating whether or not the lock is
exclusive.
=cut
sub get_locks {
    my ($self, $key) = @_;


    return $self->_transaction(sub {
        my $dbh = shift;
        Store::Directories::Lock::_prune_locks($dbh, $key);

        my $sth = $dbh->prepare("SELECT pid, exclusive FROM lock WHERE slug = ?");
        $sth->execute($key) or croak "Failed to fetch locks: ".$dbh->errstr;
        my %locks = %{ $sth->fetchall_hashref('pid') };
        $dbh->err and croak "Failed to fetch locks: ".$dbh->errstr;

        @locks{keys %locks} = map { $_->{exclusive} ? 1 : 0 } values %locks;
        return \%locks;
    });
}

=item * B<get_listing>

Returns a hashref listing all of the directories in the store. Each key in the
hash is the key for that directory while the corresponding value is the
absolute path to the directory.
=cut
sub get_listing {
    my $self = shift;

    my $dbh = $self->_new_connection;

    my %entries = %{
        $dbh->selectall_hashref("SELECT slug, dir FROM entry", 'slug');
    };
    $dbh->err and croak "Failed to fetch entries: ".$dbh->errstr;

    @entries{keys %entries} = map { 
        catfile( $self->{dir}, $_->{dir} )
    } values %entries;
    return \%entries;
}

=back

=cut

########################
# PRIVATE INTERFACE
########################

#
# (Some of these functions will require you to pass in 
# a database handle for them to use and assume they are
# being called as part of a larger transaction. They will also
# croak on failure)
#

########################
# PRIVATE METHODS
########################

# $self->_new_connection [Attrs]
# Create and return a new connection to the
# SQLite database
sub _new_connection {
    my $self = shift;
    my %attrs = (
        PrintError          => 0,
        AutoCommit          => 1,
        AutoInactiveDestroy => 1,
        sqlite_use_immediate_transaction => 1
    );

    my $dbh = DBI->connect(
        "dbi:SQLite:dbname=".$self->{dbfile},
        "", "",
        { %attrs, @_ }
    );
    croak "Failed to connect to database." unless $dbh;
    return $dbh;
}

# $self->_transaction [DBH] SUB
# Execute the given subroutine in a new database transaction.
# The subroutine will be called with the database handle
# as the first, and only argument.
# On success, returns whatever the given subroutine returns,
# otherwise croaks with same message as the subroutine.
sub _transaction {
    my $self = shift;

    my $dbh, my $sub;
    if (@_ > 1) {
        $dbh = shift;
        $sub = shift;
    } else {
        $dbh = $self->_new_connection;
        $sub = shift;
    }

    $dbh->begin_work;
    defined $dbh->err and croak "Could not start transaction: ".$dbh->errstr;

    my $ret;
    eval { $ret = $sub->($dbh); 1 } or do {
        $dbh->rollback;
        croak "Error in transaction: $@";
    };

    $dbh->commit;
    return $ret;

}

# $self->_add_directory DBH KEY
# Add a directory to the database and create it on disk.
sub _add_directory {
    my ($self, $dbh, $key) = @_;

    # Get directory names in database
    my $names = $dbh->selectall_hashref("SELECT dir FROM entry;", 'dir');
    defined $names or croak "Failed to fetch from database: ".$dbh->errstr;

    # Find a new UUID
    my $uuid;
    do { $uuid = $UUIDGEN->create_str() } while (exists $names->{$uuid});

    # Insert
    my $sth = $dbh->prepare("INSERT INTO entry (slug, dir) VALUES (? , ?);");
    my $rv  = $sth->execute($key, $uuid);

    unless (defined $rv) {
        # The key already being in the store is a pretty predictable error,
        # so if that's what caused the error, then we'll catch it and
        # report a more user-friendly error message.
        croak   $dbh->errstr =~ m/UNIQUE.*slug/i
                ? "Key '$key' already in store."
                : "Failed to insert entry into database: ".$dbh->errstr;
    }

    # Create directory
    my $dir = catfile($self->{dir}, $uuid);
    make_path($dir);

    return $dir;
}

# $self->_remove_directory_from_db DBH KEY
# Remove a directory from the database
sub _remove_directory_from_db {
    my ($self, $dbh, $key) = @_;

    my $sth = $dbh->prepare("DELETE FROM entry WHERE slug = ?");
    $sth->execute($key);
    $dbh->err and croak "Failed to delete entry from database. ".$dbh->errstr;

    1;
}

# $self->_remove_directory_from_disk PATH
# Remove the given subdirectory of the store from disk.
sub _remove_directory_from_disk {
    my $self = shift;
    my $dirname   = shift;
    my $path      = catfile($self->{dir}, $dirname);
    my $abspath   = abs_path($path);
    # Before doing a dangerous `rm -r`, ensure that the directory exists
    # and that it really is a subdirectory of the cache
    unless (-d $path and $abspath eq $path ) {
        die "Could not find directory '$dirname' inside store.";
    }
    system( qw'chmod -R +rwx', $abspath);
    system( qw'rm -r --one-file-system', $path);
    1;
}

########################
# PRIVATE FUNCTIONS
########################

# _init_db DBH
# Initialize the tables in the SQLite database
sub _init_db {
    my $dbh  = shift;

    my $schema;
    open(my $fh, '<', $sql_schema) 
        or croak "could not open database schema '$sql_schema': $!";
    { local $/ = undef; $schema = <$fh>; }
    close $fh;

    my $splitter = SQL::SplitStatement->new;
    my @statements = $splitter->split($schema);

    for (@statements) {
        $dbh->do($_);
        croak "Error initializing database: ".$dbh->errstr if defined $dbh->err;
    }

    1;
}

1;

=head1 AUTHOR

Cameron Tauxe C<camerontauxe@gmail.com>


=head1 LICENSE AND COPYRIGHT

This software is copyright (c) 2020 by Cameron Tauxe.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
