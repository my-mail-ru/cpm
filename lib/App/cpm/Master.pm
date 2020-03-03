package App::cpm::Master;
use strict;
use warnings;

use App::cpm::CircularDependency;
use App::cpm::Distribution;
use App::cpm::Job;
use App::cpm::Git;
use App::cpm::Logger;
use App::cpm::version;
use CPAN::DistnameInfo;
use IO::Handle;
use Module::Metadata;

sub new {
    my ($class, %option) = @_;
    my $self = bless {
        %option,
        installed_distributions => 0,
        jobs => +{},
        distributions => +{},
        _fail_resolve => +{},
        _fail_install => +{},
        _is_installed => +{},
    }, $class;
    if ($self->{target_perl}) {
        require Module::CoreList;
        if (!exists $Module::CoreList::version{$self->{target_perl}}) {
            die "Module::CoreList does not have target perl $self->{target_perl} entry, abort.\n";
        }
        if (!exists $Module::CoreList::version{$]}) {
            die "Module::CoreList does not have our perl $] entry, abort.\n";
        }
    }
    if (!$self->{global}) {
        if (eval { require Module::CoreList }) {
            if (!exists $Module::CoreList::version{$]}) {
                die "Module::CoreList does not have our perl $] entry, abort.\n";
            }
            $self->{_has_corelist} = 1;
        } else {
            my $msg = "You don't have Module::CoreList. "
                    . "The local-lib may result in incomplete self-contained directory.";
            App::cpm::Logger->log(result => "WARN", message => $msg);
        }
    }
    $self;
}

sub fail {
    my $self = shift;

    my @fail_resolve = sort keys %{$self->{_fail_resolve}};
    my @fail_install = sort keys %{$self->{_fail_install}};
    my @not_installed = grep { !$self->{_fail_install}{$_->distfile} && !$_->installed } $self->distributions;
    return if !@fail_resolve && !@fail_install && !@not_installed;

    my $detector = App::cpm::CircularDependency->new;
    for my $dist (@not_installed) {
        my $req = $dist->requirements([qw(configure build test runtime)])->as_array;
        $detector->add($dist->distfile, $dist->provides, $req);
    }
    $detector->finalize;

    my $detected = $detector->detect;
    for my $distfile (sort keys %$detected) {
        my $distvname = $self->distribution($distfile)->distvname;
        my @circular = @{$detected->{$distfile}};
        my $msg = join " -> ", map { $self->distribution($_)->distvname } @circular;
        local $self->{logger}{context} = $distvname;
        $self->{logger}->log_fail("Detected circular dependencies $msg");
        $self->{logger}->log_fail("Failed to install distribution");
    }
    for my $dist (sort { $a->distvname cmp $b->distvname } grep { !$detected->{$_->distfile} } @not_installed) {
        local $self->{logger}{context} = $dist->distvname;
        $self->{logger}->log_fail("Failed to install distribution, "
                            ."because of installing some dependencies failed");
    }

    my @name = (
        (map { CPAN::DistnameInfo->new($_)->distvname || $_ } @fail_install),
        (map { $_->distvname } @not_installed),
    );
    { resolve => \@fail_resolve, install => [sort @name] };
}

sub jobs { values %{shift->{jobs}} }

sub add_job {
    my ($self, %job) = @_;
    my $new = App::cpm::Job->new(%job);
    if (grep { $_->equals($new) } $self->jobs) {
        return 0;
    } else {
        $self->{jobs}{$new->uid} = $new;
        return 1;
    }
}

sub get_job {
    my $self = shift;
    if (my @job = grep { !$_->in_charge } $self->jobs) {
        return @job;
    }
    $self->_calculate_jobs;
    return unless $self->jobs;
    if (my @job = grep { !$_->in_charge } $self->jobs) {
        return @job;
    }
    return;
}

sub register_result {
    my ($self, $result) = @_;
    my ($job) = grep { $_->uid eq $result->{uid} } $self->jobs;
    die "Missing job that has uid=$result->{uid}" unless $job;

    %{$job} = %{$result}; # XXX

    my $logged = $self->info($job);
    my $method = "_register_@{[$job->{type}]}_result";
    $self->$method($job);
    $self->remove_job($job);
    $self->_show_progress if $logged && $self->{show_progress};

    return 1;
}

sub info {
    my ($self, $job) = @_;
    my $type = $job->type;
    return if !$App::cpm::Logger::VERBOSE && $type ne "install";
    my $name = $job->distvname;
    my ($message, $optional);
    if ($type eq "resolve") {
        $message = $job->{package};
        $message .= " -> $name" . ($job->{rev} ? "\@$job->{rev}" : "") if $job->{ok};
        $optional = "from $job->{from}" if $job->{ok} and $job->{from};
    } else {
        $message = $name;
        $message .= " ($job->{uri}" . ($job->{rev} ? "\@$job->{rev}" : "") . ")" if $job->{source} eq 'git';
        $optional = "using cache" if $type eq "fetch" and $job->{using_cache};
        $optional = "using prebuilt" if $job->{prebuilt};
    }
    my $elapsed = defined $job->{elapsed} ? sprintf "(%.3fsec) ", $job->{elapsed} : "";

    App::cpm::Logger->log(
        pid => $job->{pid},
        type => $type,
        result => $job->{ok} ? "DONE" : "FAIL",
        message => "$elapsed$message",
        optional => $optional,
    );
    return 1;
}

sub _show_progress {
    my $self = shift;
    my $all = keys %{$self->{distributions}};
    my $num = $self->installed_distributions;
    print STDERR "--- $num/$all ---";
    STDERR->flush; # this is needed at least with perl <= 5.24
}

sub remove_job {
    my ($self, $job) = @_;
    delete $self->{jobs}{$job->uid};
}

sub distributions { values %{shift->{distributions}} }

sub distribution {
    my ($self, $distfile) = @_;
    $self->{distributions}{$distfile};
}

sub _calculate_jobs {
    my $self = shift;

    my @distributions
        = grep { !$self->{_fail_install}{$_->distfile} } $self->distributions;

    if (my @dists = grep { $_->resolved && !$_->registered } @distributions) {
        for my $dist (@dists) {
            $dist->registered(1);
            $self->add_job(
                type => "fetch",
                distfile => $dist->{distfile},
                source => $dist->source,
                uri => $dist->uri,
                rev => $dist->rev,
                ref => $dist->ref,
                features => $dist->{features},
            );
        }
    }

    if (my @dists = grep { $_->fetched && !$_->registered } @distributions) {
        for my $dist (@dists) {
            local $self->{logger}->{context} = $dist->distvname;
            my $dist_requirements = $dist->requirements('configure')->as_array;
            my ($is_satisfied, $conflict_req, @need_resolve) = $self->is_satisfied($dist_requirements);
            if ($conflict_req) {
                $dist->deps_registered(1);
                $self->{_fail_install}{$dist->distfile}++;
            } elsif ($is_satisfied) {
                $dist->registered(1);
                $self->add_job(
                    type => "configure",
                    meta => $dist->meta,
                    directory => $dist->directory,
                    distfile => $dist->{distfile},
                    source => $dist->source,
                    uri => $dist->uri,
                    rev => $dist->rev,
                    ref => $dist->ref,
                    version => $dist->version,
                    distvname => $dist->distvname,
                    features => $dist->{features},
                );
            } elsif (@need_resolve and !$dist->deps_registered) {
                $dist->deps_registered(1);
                my $msg = sprintf "Found configure dependencies: %s",
                    join(", ", map { sprintf "%s (%s%s)", $_->{package}, $_->{version_range} || 0, ($_->{options} && $_->{options}->{git} ? sprintf(", %s %s", $_->{options}->{git}, $_->{options}->{ref}||'master'): '') }  @need_resolve);
                $self->{logger}->log($msg);
                my $ok = $self->_register_resolve_job(@need_resolve);
                $self->{_fail_install}{$dist->distfile}++ unless $ok;
            } elsif (!defined $is_satisfied) {
                my ($req) = grep { $_->{package} eq "perl" } @$dist_requirements;
                my $msg = sprintf "%s requires perl %s, but you have only %s",
                    $dist->distvname, $req->{version_range}, $self->{target_perl} || $];
                $self->{logger}->log_fail($msg);
                App::cpm::Logger->log(result => "FAIL", message => $msg);
                $self->{_fail_install}{$dist->distfile}++;
            }
        }
    }

    if (my @dists = grep { $_->configured && !$_->registered } @distributions) {
        for my $dist (@dists) {
            local $self->{logger}->{context} = $dist->distvname;

            my @phase = qw(build test runtime);
            push @phase, 'configure' if $dist->prebuilt;
            my $dist_requirements = $dist->requirements(\@phase)->as_array;
            my ($is_satisfied, $conflict_req, @need_resolve) = $self->is_satisfied($dist_requirements);
            if ($conflict_req) {
                $dist->deps_registered(1);
                $self->{_fail_install}{$dist->distfile}++;
            } elsif ($is_satisfied) {
                $dist->registered(1);
                $self->add_job(
                    type => "install",
                    meta => $dist->meta,
                    distdata => $dist->distdata,
                    directory => $dist->directory,
                    distfile => $dist->{distfile},
                    distvname => $dist->distvname,
                    source => $dist->source,
                    uri => $dist->uri,
                    rev => $dist->rev,
                    ref => $dist->ref,
                    static_builder => $dist->static_builder,
                    prebuilt => $dist->prebuilt,
                    features => $dist->{features},
                );
            } elsif (@need_resolve and !$dist->deps_registered) {
                $dist->deps_registered(1);
                my $msg = sprintf "Found dependencies: %s",
                    join(", ", map { sprintf "%s (%s%s)", $_->{package}, ($_->{version_range} || 0), ($_->{options} && $_->{options}->{git} ? sprintf(", %s %s", $_->{options}->{git}, $_->{options}->{ref}||'master'): '') }  @need_resolve);
                $self->{logger}->log($msg);
                my $ok = $self->_register_resolve_job(@need_resolve);
                $self->{_fail_install}{$dist->distfile}++ unless $ok;
            } elsif (!defined $is_satisfied) {
                my ($req) = grep { $_->{package} eq "perl" } @$dist_requirements;
                my $msg = sprintf "%s requires perl %s, but you have only %s",
                    $dist->distvname, $req->{version_range}, $self->{target_perl} || $];
                $self->{logger}->log_fail($msg);
                App::cpm::Logger->log(result => "FAIL", message => $msg);
                $self->{_fail_install}{$dist->distfile}++;
            }
        }
    }
}

sub _register_resolve_job {
    my ($self, @package) = @_;
    my $ok = 1;
    for my $package (@package) {
        if ($self->{_fail_resolve}{$package->{package}}
            || $self->{_fail_install}{$package->{package}}
        ) {
            $ok = 0;
            next;
        }

        $self->add_job(
            type => "resolve",
            reinstall => ($self->{reinstall}||0),
            package => $package->{package},
            version_range => $package->{version_range},
            ($package->{options} && $package->{options}->{features} ? (
                features => $package->{options}->{features},
            ) : ()),
            ($package->{options} && $package->{options}->{git} ? (
                source => 'git',
                uri => $package->{options}->{git},
                ref => $package->{options}->{ref},
            ) : ()),
        );
    }
    return $ok;
}

sub is_satisfied_perl_version {
    my ($self, $version_range) = @_;
    App::cpm::version->parse($self->{target_perl} || $])->satisfy($version_range);
}

sub is_installed {
    my ($self, $package, $version_range, $rev) = @_;
    my $wantarray = wantarray;
    if (exists $self->{_is_installed}{$package}) {
        if ($self->{_is_installed}{$package}->satisfy($version_range)) {
            return $wantarray ? (1, $self->{_is_installed}{$package}) : 1;
        }
    }
    my $info = Module::Metadata->new_from_module($package, inc => $self->{search_inc});
    unless ($info) {
        $self->{_is_reinstalled}{$package}++ if $self->{reinstall};
        return;
    }

    my $is_core_inc = 0;
    if (!$self->{global} and $self->{_has_corelist} and $self->_in_core_inc($info->filename)) {
        # https://github.com/miyagawa/cpanminus/blob/7b574ede70cebce3709743ec1727f90d745e8580/Menlo-Legacy/lib/Menlo/CLI/Compat.pm#L1783-L1786
        # if found package in core inc,
        # but it does not list in CoreList,
        # we should treat it as not being installed
        return if !exists $Module::CoreList::version{$]}{$info->name};
        $is_core_inc = 1;
    }
    if ($self->{reinstall} && $info) {
        my $reinstall_distrib = $package;
        for my $distr (grep {$_->configured || $_->installed} $self->distributions) {
            for (@{$distr->provides}) {
                if ($_->{package} eq $package) {
                    $reinstall_distrib = $distr->distdata ? $distr->distdata->{module_name} : $distr->meta->{name};
                    last;
                }
            }
        }
        return($wantarray ? (0,0) : 0) if !$is_core_inc && !($self->{_is_reinstalled}{$package}++ || ($reinstall_distrib ne $package && $self->{_is_reinstalled}{$reinstall_distrib}++));
    }

    my $current_version = $self->{_is_installed}{$package}
                        = App::cpm::version->parse($info->version);
    my $ok = $current_version->satisfy($version_range);
    return $ok if !$wantarray && (!$rev || !$ok);
    my $current_rev = App::cpm::Git->module_rev($info->filename);
    $ok &&= App::cpm::Git->rev_is($rev, $current_rev) if $rev;
    return $wantarray ? ($ok, $current_version, $current_rev) : $ok;
}

sub _in_core_inc {
    my ($self, $file) = @_;
    !!grep { $file =~ /^\Q$_/ } @{$self->{core_inc}};
}

sub is_core {
    my ($self, $package, $version_range) = @_;
    my $target_perl = $self->{target_perl};
    if (exists $Module::CoreList::version{$target_perl}{$package}) {
        if (!exists $Module::CoreList::version{$]}{$package}) {
            if (!$self->{_removed_core}{$package}++) {
                my $t = App::cpm::version->parse($target_perl)->normal;
                my $v = App::cpm::version->parse($])->normal;
                App::cpm::Logger->log(
                    result => "WARN",
                    message => "$package used to be core in $t, but not in $v, so will be installed",
                );
            }
            return;
        }
        return 1 unless $version_range;
        my $core_version = $Module::CoreList::version{$target_perl}{$package};
        return App::cpm::version->parse($core_version)->satisfy($version_range);
    }
    return;
}

# 0:     not satisfied, need wait for satisfying requirements
# 1:     satisfied, ready to install
# undef: not satisfied because of perl version
sub is_satisfied {
    my ($self, $requirements) = @_;
    my $is_satisfied = 1;
    my $is_conflict = 0;
    my @need_resolve;
    my @distributions = $self->distributions;
    for my $req (@$requirements) {
        my ($package, $version_range) = @{$req}{qw(package version_range)};
        if ($package eq "perl") {
            $is_satisfied = undef if !$self->is_satisfied_perl_version($version_range);
            next;
        }
        next if $self->{target_perl} && $self->is_core($package, $version_range);
        my ($resolved) = grep { $_->providing($package, $version_range, $req->{options}->{ref}) } @distributions;
        if ($resolved) {
            my $req_source = $req->{options}->{git}||'not a git repo';
            if (($resolved->{source} ne 'git' && !exists $req->{options}->{git}) || $resolved->{uri} eq $req_source) {
                if ($self->{reinstall}) {
                    next if $self->is_installed($package, $version_range, $req->{options}->{ref});
                    push @need_resolve, $req;
                }
                elsif ($resolved->installed) {
                    next;
                }
            }
            else {
                my $message = "Conflict source for package `$package`. Required $req_source, installed $resolved->{uri}";
                $self->{logger}->log_fail($message);
                $is_conflict = 1;
            }
        }
        else {
            next if $self->is_installed($package, $version_range, $req->{options}->{ref});
            push @need_resolve, $req;
        }
        $is_satisfied = 0 if defined $is_satisfied;
    }
    return ($is_satisfied, $is_conflict, @need_resolve);
}

sub add_distribution {
    my ($self, $distribution) = @_;
    my $distfile = $distribution->distfile;
    if (my $already = $self->{distributions}{$distfile}) {
        $already->overwrite_provide($_) for @{ $distribution->provides };
        return 0;
    } else {
        $self->{distributions}{$distfile} = $distribution;
        return 1;
    }
}

sub _register_resolve_result {
    my ($self, $job) = @_;
    if (!$job->is_success) {
        $self->{_fail_resolve}{$job->{package}}++;
        return;
    }

    local $self->{logger}{context} = $job->{package};
    if ($job->{distfile} and $job->{distfile} =~ m{/perl-5[^/]+$}) {
        my $message = "Cannot upgrade core module $job->{package}.";
        $self->{logger}->log_fail($message);
        App::cpm::Logger->log(
            result => "FAIL",
            type => "install",
            message => $message,
        );
        $self->{_fail_install}{$job->{package}}++; # XXX
        return;
    }

    if (!$job->{reinstall}) {
        my $want = $job->{version_range} || $job->{version};
        my $want_rev = $job->{ref} ? $job->{rev} : undef;
        my ($ok, $local, $local_rev) = $self->is_installed($job->{package}, $want, $want_rev);
        if ($ok) {
            my $eq = $job->{rev} ? App::cpm::Git->rev_is($job->{rev}, $local_rev)
                : $job->{version} ? App::cpm::version->parse($job->{version}) == $local
                : undef;
            my $message = $job->{package} . ($eq ? " is up to date. ($local)" : ", you already have $local");
            $self->{logger}->log($message);
            App::cpm::Logger->log(
                result => "DONE",
                type => "install",
                message => $message,
            );
            return;
        }
    }

    my $provides = $job->{provides};
    if (!$provides or @$provides == 0) {
        my $version = App::cpm::version->parse($job->{version}) || 0;
        $provides = [{package => $job->{package}, version => $version, ($job->{ref} ? (ref => $job->{ref}) : ())}];
    }
    $_->{ref} ||= $job->{ref} for @{$provides};

    my $distribution = App::cpm::Distribution->new(
        source   => $job->{source},
        uri      => $job->{uri},
        provides => $provides,
        distfile => $job->{distfile},
        rev      => $job->{rev},
        ref      => $job->{ref},
        features => $job->{options}->{features},
    );
    $self->add_distribution($distribution);
}

sub _register_fetch_result {
    my ($self, $job) = @_;
    if (!$job->is_success) {
        $self->{_fail_install}{$job->distfile}++;
        return;
    }
    my $distribution = $self->distribution($job->distfile);
    $distribution->directory($job->{directory});
    $distribution->meta($job->{meta});
    $distribution->provides($job->{provides});
    if ($job->{source} eq 'git') {
        $distribution->rev($job->{rev});
        $distribution->version($job->{version});
        $distribution->distvname($job->{meta}->{name} . "-" . $job->{meta}->{version}) if $job->{meta}->{name};
    }

    if ($job->{prebuilt}) {
        $distribution->configured(1);
        $distribution->requirements($_ => $job->{requirements}{$_}) for keys %{$job->{requirements}};
        $distribution->prebuilt(1);
        local $self->{logger}{context} = $distribution->distvname;
        my $msg = join ", ", map { sprintf "%s (%s)", $_->{package}, $_->{version} || 0 } @{$distribution->provides};
        $self->{logger}->log("Distribution provides: $msg");
    } else {
        $distribution->fetched(1);
        $distribution->requirements($_ => $job->{requirements}{$_}) for keys %{$job->{requirements}};
    }
    return 1;
}

sub _register_configure_result {
    my ($self, $job) = @_;
    if (!$job->is_success) {
        $self->{_fail_install}{$job->distfile}++;
        return;
    }
    my $distribution = $self->distribution($job->distfile);
    $distribution->configured(1);
    $distribution->requirements($_ => $job->{requirements}{$_}) for keys %{$job->{requirements}};
    $distribution->static_builder($job->{static_builder});
    $distribution->distdata($job->{distdata});

    if ($distribution->source eq 'git') {
        $distribution->distvname($job->{distdata}->{distvname});
    }

    # After configuring, the final "provides" is fixed.
    # So we need to re-define "provides" here
    my $p = $job->{distdata}{provides};
    my @provide = map +{ package => $_, version => $p->{$_}{version}, ($job->{ref} ? (ref => $job->{ref}) : ())}, sort keys %$p;
    $distribution->provides(\@provide);
    local $self->{logger}{context} = $distribution->distvname;
    my $msg = join ", ", map { sprintf "%s (%s)", $_->{package}, $_->{version} || 0 } @{$distribution->provides};
    $self->{logger}->log("Distribution provides: $msg");
    return 1;
}

sub _register_install_result {
    my ($self, $job) = @_;
    if (!$job->is_success) {
        $self->{_fail_install}{$job->distfile}++;
        return;
    }
    my $distribution = $self->distribution($job->distfile);
    $distribution->installed(1);
    $self->{installed_distributions}++;
    return 1;
}

sub installed_distributions {
    shift->{installed_distributions};
}

1;
