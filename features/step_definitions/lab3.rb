def next_line(id)
  # We need exclusive access to @line_thread as there is a race
  # between the watchdog thread killing the thread and this code
  # creating the thread.
  @line_lock[id].lock

  # If the subprocess has already been killed then we can't possibly
  # proceed, any test asking for output must be already failed
  if (@qemu_out_pipe[id] == nil)
    @line_lock[id].unlock
    fail
  end

  # Start a thread that gets a single line -- this exists because we
  # might want to kill the waiting request.  I'm shying away from
  # using non-blocking IO here with the hope that this will make
  # writing tests easier
  @line[id] = nil
  @line_thread[id] = Thread.new{
    @line[id] = @qemu_out_pipe[id].gets

    # I'm considering the race here to be unimportant -- is there
    # really any difference between a watchdog that runs for N seconds
    # vs a watchdog that runs for N seconds minus a few instructions?
    # I think not.
    @watchdog_set[id] = true
  }

  # Now that the thread has been started up there is no longer a race
  # condition
  @line_lock[id].unlock

  # Wait for the thread to finish, implicitly using the ending
  # condition that "@line == nil" to indicate that the thread was
  # killed prematurely
  @line_thread[id].join
  @line_thread[id] = nil
  if (@line[id] == nil)
    fail
  end

  return @line[id]
end

# Writes a single line to QEMU.  This just forces a flush after every
# line -- while it's not particularly good for performance reasons, we
# need it for interactivity.
def write_line(line, id)
  @qemu_in_pipe[id].puts(line)
  @qemu_in_pipe[id].flush
end

# This fetches a single line from the kernel but ensures that it's not
# been given a printk-looking message
def next_line_noprintk(id)
  while (/\[ *[0-9]*\.[0-9]*\] /.match(next_line(id)))
  end

  return @line[id]
end

# Kills the currently running QEMU instance in an entirely safe manner
def kill_qemu(id=0)
  # We need a lock here to avoid the race between starting up the
  # thread that reads from QEMU and killing it.
  @line_lock[id].lock

  # First, go ahead and kill the QEMU process we started earlier.
  # Also clean up the pipes that QEMU made
  Process.kill('INT', @qemu_process[id].pid)

  # NOTE: it's very important we DON'T cleanup the sockets here, as
  # something else might still need access to them.  I should really
  # figure out Cucumber's pre and post hooks so we can clean things
  # up.
  #`./boot_qemu --cleanup`

  # Killing this thread causes any outstanding read request.  This
  # will result in a test failure, but I can't just do it right now
  # because then this test will still block forever
  if (@line_thread[id] != nil)
    @line_thread[id].kill
    @line_thread[id] = nil
  end

  # Ensure nobody else attempts to communicate with the now defunct
  # QEMU process
  @qemu_out_pipe[id] = nil
  @qemu_in_pipe[id] = nil
  @qemu_mout_pipe[id] = nil
  @qemu_min_pipe[id] = nil
  running = false

  # This critical section could probably be shrunk, but we're just
  # killing everything so I've err'd a bit on the safe side here.
  @line_lock[id].unlock

  # Informs the file waiting code that it should stop trying to wait
  @qemu_running[id] = false
end

# This waits for a file before opening it.  I can't figure out why I
# can't call this "File.wait_open()", which is what I think it should
# be called...
def file_wait_open(filename, options, id)
  while (!File.exists?(filename) && @qemu_running[id])
    STDERR.puts "Waiting on #{filename}"
    sleep(1)
  end

  return File.open(filename, options)
end

def boot_linux(boot_args, id=0)
  # This lock ensures we aren't brining down the VM while also trying
  # to read a line from stdout -- this will cause the read to block
  # forever
  @line_lock[id] = Mutex.new

  # Start up QEMU in the background, note the implicit "--pipe"
  # argument that gets added here that causes QEMU to redirect
  @qemu_process[id] = IO.popen("./boot_qemu --pipe#{id} #{boot_args}", "r")
  @qemu_running[id] = true

  # This ensures that QEMU hasn't terminated without us knowing about
  # it, which would cause the tests to hang on reading.
  @qemu_watcher[id] = Thread.new{
    puts @qemu_process[id].readlines
    kill_qemu(id)
  }

  # FIXME: Wait for a second so the FIFO pipes get created, this
  # should probably poll or something, but I'm lazy
  sleep(1)
  @qemu_in_pipe[id] = file_wait_open("qemu_serial_pipe#{id}.in", "w+", id)
  @qemu_out_pipe[id] = file_wait_open("qemu_serial_pipe#{id}.out", "r+", id)
  @qemu_min_pipe[id] = file_wait_open("qemu_monitor_pipe#{id}.in", "w+", id)
  @qemu_mout_pipe[id] = file_wait_open("qemu_monitor_pipe#{id}.out", "r+", id)

  # Skip QEMU's help message
  @monitor_thread_read[id] = false
  @monitor_thread[id] = Thread.new{
    @qemu_mout_pipe[id].gets
    @monitor_thread_read[id] = true
  }

  # Start up a watchdog timer, this ensures that the Linux system
  # doesn't just hang.  This has the side effect of killing the
  # instance whenever it doesn't produce output for a while, but I
  # guess that's OK...
  @watchdog_set[id] = false
  @watchdog_thread[id] = Thread.new{
    running = true
    while (running)
      # Tune this interval based on how often messages must come in.
      sleep(10)

      # If no messages have come in between this check and the last
      # check then go ahead and kill QEMU -- it must be hung
      if (@watchdog_set[id] == false)
        kill_qemu(id)
      end

      # Clear the watchdog, it'll have to get set again before another
      # timer round expires otherwise we'll end up killing QEMU!
      @watchdog_set[id] = false
    end
  }

  # Reads from the input pipe until we get a message saying that Linux
  # has initialized.  It's very important that any init the user
  # supplies prints out this message (or kernel panics) otherwise
  # we'll end up just spinning while waiting for an already
  # initialized Linux.
  init_regex = /^\[cs194-24\] init running/
  panic_regex = /^\[ *[0-9]*\.[0-9]*\] Kernel panic - not syncing/
  running = true
  while (running)
    next_line(id)

    if (init_regex.match(@line[id]))
      running = false
    elsif (panic_regex.match(@line[id]))
      STDERR.puts("kernel panic during init: #{@line[id]}")
      running = false
    end
  end

  # Ensure the monitor thread has actually gotten a line from the QEMU
  # monitor -- otherwise we'll be all out of sync later...
  if (@monitor_thread_read[id] == false)
    fail
  end
end

def kill_linux(id=0)
  # Look for Linux's power-off message
  while !(/\[ *[0-9]*\.[0-9]*\] Power down\./.match(next_line(id)))
    STDERR.puts(@line[id])
    # A clean shutdown means that the code can't kernel panic.
    if (/^\[.*\] Kernel panic/.match(@line[id]))
      fail
    end
  end
end

def qemu_cleanup()
  # Clean up after any potential left over QEMU cruft
  `./boot_qemu --cleanup`

  pids = `ps -Ao "%p,%a" | grep -i qemu | cut -d ',' -f 1 | xargs`

  `kill #{pids}`
end

def set_ip(id=0)
  write_line("ifconfig eth0 #{@linux_ip[id]}", id)
end

def linux_execute(command, id)
  write_line(command, id)
  sleep(1)
end

def host_execute(command)
  `#{command}`
end

def ping(count, from, to)
  write_line("ping -c #{count} -s 5000 #{@linux_ip[to]}", from)
  while !(/^.*packets transmitted.*$/.match(next_line(from)))
    #puts @line[from]
  end
  puts @line[from]
  if !(/^.*packets transmitted.*, 0%.packet loss/.match(@line[from]))
    fail
  end
end

def linux_not_output(text, fin, id)
  text = Regexp.escape(text)
  #fin = Regexp.escape(fin)

  begin
    next_line(id)
    puts @line[id].inspect

    if /^.*#{text}.*$/.match(@line[id])
      fail
    end
  end while !(/^.*#{fin}.*$/.match(@line[id]))
end

def initialize_tests()
  @line_lock = []
  @qemu_out_pipe = []
  @qemu_in_pipe = []
  @qemu_mout_pipe = []
  @qemu_min_pipe = []
  @line_thread = []
  @qemu_process = []

  @monitor_thread_read = []
  @monitor_thread = []

  @qemu_running = []
  @qemu_watcher = []
  @watchdog_set = []
  @watchdog_thread = []

  @line = []

  @linux_ip = ["10.0.2.15", "10.0.2.16"]
  return
end

Given /^Initialize tests$/ do
  initialize_tests
end

Given /^Linux is booted with "(.*?)"$/ do |boot_args|
  boot_linux boot_args
  set_ip
end

And /^Linux2 is booted with "(.*?)"$/ do |boot_args|
  boot_linux boot_args, 1
  set_ip 1
end

Then /^Linux should shut down cleanly$/ do
  kill_qemu
end

And /^Linux2 should shut down cleanly$/ do
  kill_qemu 1
end

And /^Cleanup Qemu cruft$/ do
  qemu_cleanup
end

Then /^Linux(.) ping Linux(.) ([0-9]+) times$/ do | node1, node2, count |
  ping count.to_i, node1.to_i - 1, node2.to_i - 1
  sleep(0.5)
end

Then /^Linux(.) execute "(.*?)"$/ do | id, command |
  linux_execute command, id.to_i - 1
end

And /^Host execute "(.*?)"$/ do | command |
  host_execute command
end

Then /^Linux(.) output does not contain "(.*?) stop at "(.*?)"/ do | id, text, fin |
  linux_not_output text, fin, id.to_i - 1
end

# initialize_tests
# boot_linux("--net ne2k_pci,macaddr=0A:0A:0A:0A:0A:0A")
# boot_linux("--net ne2k_pci,macaddr=0A:0A:0A:0A:0B:0B --node2",1)
# kill_qemu(0)
# kill_qemu(1)
# qemu_cleanup
