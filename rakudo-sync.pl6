#!/usr/bin/env perl6

use YAML;

my @paths = yaml-parser($*HOME.add(".rakudo-sync.yml"));

class FswatchRecursiveHandler {
    enum UpdateType<info fswatch-stderr state-change file-change rsync-stdout rsync-stderr rsync-finished heartbeat>;
    enum Status<idle standby syncing>;
    has Status:D $.status = idle;
    has IO::Path $.top;
    has Str $.to;
    has List:D $.ignore-patterns = List.new;
    has Supplier:D %!updates = UpdateType.enums.map({ $_.key => Supplier.new });
    has Supplier:D $!exit = Supplier.new;
    has Bool:D $!wants-exit = False;
    has Supplier:D $!changed-paths = Supplier.new;
    has SetHash:D $!ignored-paths = SetHash.new;
    has Supplier:D $!holdoff-timer = Supplier.new;
    has DateTime $!holdoff-time = DateTime.now;
    has Bool:D $!entered-holdoff = False;
    has Bool:D $!needs-ignore-scan = False;
    has Status:D $!after-sync = idle;
    has Proc::Async $!rsync-process;
    constant fuzz-factor = 0.1;
    constant holdoff-delay = 1.0;

    method Supply(*@type) {
        Supply.merge(%!updates.{@type}.map({$_.Supply}));
    }

    method !schedule-holdoff {
        return if $!entered-holdoff;
        $!entered-holdoff = True;
        my $delta = $!holdoff-time - DateTime.now + fuzz-factor;
        $delta = fuzz-factor if $delta < fuzz-factor;
        $!holdoff-timer.emit: Supply.interval($delta).head(1);
    }

    method !emit-event(UpdateType:D $type, *@args) {
        %!updates{$type}.emit: (self, $type, @args).flat;
    }

    method !set-status(Status:D $status) {
        $!status = $status;
        self!emit-event(state-change, $status);
    }

    method !update-ignore(IO::Path:D $path) returns Bool:D {
        my $sep = $path.SPEC.dir-sep;
        my $top_abs = $!top.absolute;
        my $path_abs = $path.absolute;

        # somehow this path exists outside our directory-root, just ignore it
        if $path_abs ne $top_abs &&
          !$path_abs.starts-with($top_abs ~ $sep) {
            return True;
        }
        my Str:D $relpath = $path_abs eq $top_abs ?? "" !! $path_abs.substr($top_abs.chars + 1);

        my Bool:D $res = False;
        PATTERN: for @$!ignore-patterns -> $pattern {
            if ($pattern.substr(0,1) eq "/") {
                my $tmp_pattern = $pattern.substr(1);
                if $relpath ~~ /^ $tmp_pattern ($|$sep)/ {
                    $res = True;
                    last PATTERN;
                }
            } elsif $relpath ~~ /(^|$sep) $pattern ($|$sep)/ {
                $res = True;
                $!ignored-paths{"/" ~ $relpath} = 1 if $1 eq "";
                last PATTERN;
            }
        }

        return $res;
    }

    method !populate-ignore {
        return unless $!needs-ignore-scan;
        self!emit-event(info, "scanning directory for ignores");
        my @todo = $!top;

        PATH: while @todo {
            my $path = @todo.shift;
            next PATH if self!update-ignore($path);

            my ($link, $dir, $exists);
            {
                $exists = $path.e;
                $link = $exists && $path.l;
                $dir = !$link && $path.d;
                CATCH {
                    when X::IO::DoesNotExist {
                    }
                }
            };

            @todo.append($path.dir.list) if $dir;
        }

        self!emit-event(info, "finished scanning: " ~ $!ignored-paths.keys);
    }

    method !process-fswatch-line(Str:D $line) {
        my $path = $line.IO;
        return if self!update-ignore($path);
        $!changed-paths.emit: $path;
    }

    method gist returns Str {
        "FSwatchRecursiveHandler(top = " ~ $!top ~ ")";
    }

    method !sync-paths {
        return if $!rsync-process;
        $!after-sync = idle;
        self!set-status(syncing);
        my Str @cmd = qw|rsync -za --delete --verbose|;
        for $!ignored-paths.keys -> $ignored-path {
            @cmd.push("--exclude", $ignored-path);
        }
        @cmd.push("--", $!top.absolute ~ "/", $!to);
        self!emit-event(info, |@cmd);
        $!rsync-process = Proc::Async.new(@cmd);

        whenever $!rsync-process.stdout.lines -> $line {
            self!emit-event(rsync-stdout, $line);
        }
        whenever $!rsync-process.stderr.lines -> $line {
            self!emit-event(rsync-stderr, $line);
        }
        whenever $!rsync-process.start -> $res {
            $!rsync-process = Proc::Async;
            self!emit-event(rsync-finished, $res.exitcode);
            self!set-status(idle);
            if $!wants-exit {
                done;
            } elsif $!after-sync != idle {
                self!sync-paths;
            }
        }
    }

    method run {
        my @fswatch_cmd = (qw|fswatch -l 0.5 -r|, $!top.path).flat;
        my $fswatch = Proc::Async.new(@fswatch_cmd);
        react {
            whenever $fswatch.stdout.lines -> $line {
                self!process-fswatch-line($line);
            }
            whenever $fswatch.stderr.lines -> $line {
                self!emit-event(fswatch-stderr, $line);
            }
            whenever $fswatch.start {
                self!emit-event(info, "fswatch ended (" ~ $_.exitcode ~ "), exiting");
                if $!rsync-process {
                    self!emit-event(info, "rsync hanging around, killing rsync");
                    $!rsync-process.kill;
                    whenever Promise.in(2) {
                        $!rsync-process.kill: SIGKILL;
                    }
                    $!wants-exit = True;
                } else {
                    done;
                }
            }
            whenever $!exit {
                self!emit-event(info, "exit requested, killing fswatch");
                whenever Promise.in(2) {
                    $fswatch.kill: SIGKILL;
                }
            }
            whenever $!changed-paths.Supply -> $path {
                self!emit-event(file-change, $path.absolute);
                if $!status == syncing {
                    $!after-sync = syncing;
                } else {
                    self!set-status(standby) if $!status == idle;
                    $!holdoff-time = DateTime.now + Duration.new(holdoff-delay);
                    self!schedule-holdoff;
                }
            }
            whenever $!holdoff-timer.Supply.migrate {
                $!entered-holdoff = False;
                my Duration:D $delta = $!holdoff-time - DateTime.now;
                if $delta.Real < 0 {
                    self!sync-paths;
                } else {
                    self!schedule-holdoff;
                }
            }
            whenever Supply.interval(60, 60) {
                self!emit-event(heartbeat);
            }
            self!populate-ignore;
            $!changed-paths.emit: $!top;
        }
        UpdateType.enums.map({ %!updates{$_.key}.done; });
    }

    method force-exit {
        $!exit.emit: True;
    }

    method TWEAK {
        $!top .= resolve;
        for @$!ignore-patterns -> $pattern {
            if ($pattern.substr(0,1) eq "/") {
                $!ignored-paths{$pattern} = 1;
            } else {
                $!needs-ignore-scan = True;
            }
        }
    }
}

my @verbosity = (
    FswatchRecursiveHandler::info,
    FswatchRecursiveHandler::fswatch-stderr,
    FswatchRecursiveHandler::state-change,
    FswatchRecursiveHandler::file-change,
);
# my @verbosity = FswatchRecursiveHandler::UpdateType.enums.map({ $_.key });

my @info = @paths.map: {
    my $res = {};
    my $runner = FswatchRecursiveHandler.new(|($_<top ignore-patterns to>:p).Capture);
    my $name = $_<name>;
    $runner.Supply(@verbosity).act: -> $status { print-info($name, |$status.Capture) };
    my $thread = start { $runner.run };
    $res<runner name thread> = $runner, $name, $thread;
    $res;
};

signal(SIGINT).act: -> $sig {
    @info.race(batch => 1).map({ $_<runner>.force-exit });
};

await Promise.anyof(@info.map({ $_<thread> }));
@info.race(batch => 1).map({ $_<runner>.force-exit });
await Promise.allof(@info.map({ $_<thread> }));

sub print-info(Str:D $name, FswatchRecursiveHandler:D $obj, FswatchRecursiveHandler::UpdateType:D $type, *@args) {
    if @args {
        say "$name: $type - ", @args.join(" ");
    } else {
        say "$name: $type";
    }
}

sub yaml-parser(IO::Path:D $path) returns Array {
    my @paths = @(yaml.load($path.slurp));
    for @paths -> $path {
        die "Missing 'name' field in yaml file" unless $path<name>;
        my $name = $path<name>;
        die "Missing 'from' field in yaml file ($name)" unless $path<from>;
        die "Missing 'to' field in yaml file ($name)" unless $path<to>;
        $path<from> .= IO;
        $path<top> = $path<from>:delete;
        $path<ignore-patterns> ||= ();
    }
    return @paths;
}
