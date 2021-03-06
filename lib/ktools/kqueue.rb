module Kernel

  class Kqueue
    extend FFI::Library

    class Kevent < FFI::Struct #:nodoc:
      layout :ident, :uint, 
      :filter, :short, 
      :flags, :ushort, 
      :fflags, :uint, 
      :data, :int, 
      :udata, :pointer
    end

    kqc = FFI::ConstGenerator.new do |c|
      c.include 'sys/event.h'

      # filters - signed short
      c.const("EVFILT_READ", "%d")
      c.const("EVFILT_WRITE", "%d")
      c.const("EVFILT_AIO", "%d")
      c.const("EVFILT_VNODE", "%d")
      c.const("EVFILT_PROC", "%d")
      c.const("EVFILT_SIGNAL", "%d")

      # flags - unsigned short
      c.const("EV_ADD", "%u")
      c.const("EV_DELETE", "%u")
      c.const("EV_ENABLE", "%u")
      c.const("EV_DISABLE", "%u")
      c.const("EV_RECEIPT", "%u")
      c.const("EV_ONESHOT", "%u")
      c.const("EV_CLEAR", "%u")
      c.const("EV_SYSFLAGS", "%u")
      c.const("EV_FLAG0", "%u")
      c.const("EV_FLAG1", "%u")
      c.const("EV_EOF", "%u")
      c.const("EV_ERROR", "%u")
      c.const("EV_POLL", "%u")
      c.const("EV_OOBAND", "%u")

      # fflags - unsigned int
      c.const("NOTE_LOWAT", "%u")
      c.const("NOTE_DELETE", "%u")
      c.const("NOTE_WRITE", "%u")
      c.const("NOTE_EXTEND", "%u")
      c.const("NOTE_ATTRIB", "%u")
      c.const("NOTE_LINK", "%u")
      c.const("NOTE_RENAME", "%u")
      c.const("NOTE_REVOKE", "%u")
      c.const("NOTE_EXIT", "%u")
      c.const("NOTE_FORK", "%u")
      c.const("NOTE_EXEC", "%u")
      c.const("NOTE_REAP", "%u")
      c.const("NOTE_SIGNAL", "%u")
      c.const("NOTE_PDATAMASK", "%u")
      c.const("NOTE_PCTRLMASK", "%u")
      c.const("NOTE_SECONDS", "%u")
      c.const("NOTE_USECONDS", "%u")
      c.const("NOTE_NSECONDS", "%u")
      c.const("NOTE_ABSOLUTE", "%u")
      c.const("NOTE_TRACK", "%u")
      c.const("NOTE_TRACKERR", "%u")
      c.const("NOTE_CHILD", "%u")
    end

    eval kqc.to_ruby

    KQ_FILTERS = {
      :read => EVFILT_READ,
      :write => EVFILT_WRITE,
      :file => EVFILT_VNODE,
      :process => EVFILT_PROC,
      :signal => EVFILT_SIGNAL
    }

    KQ_FLAGS = {
      :add => EV_ADD,
      :enable => EV_ENABLE,
      :disable => EV_DISABLE,
      :delete => EV_DELETE,
      :oneshot => EV_ONESHOT,
      :clear => EV_CLEAR
    }

    KQ_FFLAGS = {
      :delete => NOTE_DELETE,
      :write => NOTE_WRITE,
      :extend => NOTE_EXTEND,
      :attrib => NOTE_ATTRIB,
      :link => NOTE_LINK,
      :rename => NOTE_RENAME,
      :revoke => NOTE_REVOKE,
      :exit => NOTE_EXIT,
      :fork => NOTE_FORK,
      :exec => NOTE_EXEC
    }

    # Leopard has these, Tiger does not.
    KQ_FLAGS[:receipt] = EV_RECEIPT if const_defined?("EV_RECEIPT")
    KQ_FFLAGS[:signal] = NOTE_SIGNAL if const_defined?("NOTE_SIGNAL")
    KQ_FFLAGS[:reap] = NOTE_REAP if const_defined?("NOTE_REAP")

    # Had to write a wrapper for EV_SET since its a macro
    attach_function :ev_set, :wrap_evset, [:pointer, :uint, :short, :ushort, :uint, :int, :pointer], :void
    # Attach directly to kqueue function, no wrapper needed
    attach_function :kqueue, [], :int
    attach_function :kevent, [:int, :pointer, :int, :pointer, :int, :pointer], :int

    # We provide the raw C interface above. Now we OO-ify it.

    # Creates a new kqueue event queue. Will raise an error if the operation fails.
    def initialize
      @fds = {}
      @pids = {}
      @kqfd = kqueue
      raise SystemCallError.new("Error creating kqueue descriptor", get_errno) unless @kqfd > 0
      @kqfd = IO.for_fd(@kqfd)
    end

    # Generic method for adding events. This simply calls the proper add_foo method specified by the type symbol.
    # Example:
    #  kq.add(:process, pid, :events => [:fork])
    #  calls -> kq.add_process(pid, events => [:fork])
    def add(type, target, options={})
      case type
      when :socket
        add_socket(target, options)
      when :file
        add_file(target, options)
      when :process
        add_process(target, options)
      when :signal
        add_signal(target, options)
      else
        raise ArgumentError.new("Unknown event type #{type}")
      end
    end

    # Add events on a file to the Kqueue. kqueue requires that a file actually be opened (to get a descriptor)
    # before it can be monitored. You can pass a File object here, or a String of the pathname, in which
    # case we'll try to open the file for you. In either case, a File object will be returned as the :target 
    # in the event returned by #poll. If you want to keep track of it yourself, you can just pass the file
    # descriptor number (and that's what you'll get back.)
    #
    # Valid events here are as follows, using descriptions from the kqueue man pages:
    #
    # * :delete - "The unlink() system call was called on the file referenced by the descriptor."
    # * :write  - "A write occurred on the file referenced by the descriptor."
    # * :extend - "The file referenced by the descriptor was extended."
    # * :attrib - "The file referenced by the descriptor had its attributes changed."
    # * :link   - "The link count on the file changed."
    # * :rename - "The file referenced by the descriptor was renamed."
    # * :revoke - "Access to the file was revoked via revoke(2) or the underlying fileystem was unmounted."
    #
    # Example:
    #  irb(main):001:0> require 'ktools'
    #  => true
    #  irb(main):002:0> file = Tempfile.new("kqueue-test")
    #  => #<File:/tmp/kqueue-test20090417-602-evm5wc-0>
    #  irb(main):003:0> kq = Kqueue.new
    #  => #<Kernel::Kqueue:0x4f0aec @kqfd=5, @fds={}>
    #  irb(main):004:0> kq.add(:file, file, :events => [:write, :delete])
    #  => true
    #  irb(main):005:0> kq.poll
    #  => []
    #  irb(main):006:0> file.delete
    #  => #<File:/tmp/kqueue-test20090417-602-evm5wc-0>
    #  irb(main):007:0> kq.poll
    #  => [{:type=>:file, :target=>#<File:/tmp/kqueue-test20090417-602-evm5wc-0>, :events=>[:delete]}]
    #  irb(main):008:0> file.close and kq.close 
    #  => nil
    def add_file(file, options={})
      fflags, flags = options.values_at :events, :flags
      raise ArgumentError.new("must specify which file events to watch for") unless fflags

      file = file.kind_of?(String) ? File.open(file, 'r') : file
      fdnum = file.respond_to?(:fileno) ? file.fileno : file

      k = Kevent.new
      flags = flags ? flags.inject(0){|m,i| m | KQ_FLAGS[i] } : EV_CLEAR
      fflags = fflags.inject(0){|m,i| m | KQ_FFLAGS[i] }
      ev_set(k, fdnum, EVFILT_VNODE, EV_ADD | flags, fflags, 0, nil)

      if kevent(@kqfd.fileno, k, 1, nil, 0, nil) == -1
        return false
      else
        @fds[fdnum] = {:target => file, :event => k}
        return true
      end
    end

    # Add events to a socket-style descriptor (socket or pipe). Your target can be either
    # an IO object (socket, pipe), or a file descriptor number.
    #
    # Supported events are:
    #
    # * :read - The descriptor has become readable.
    # * :write - The descriptor has become writeable.
    #
    # See the kqueue manpage for how behavior differs depending on the descriptor types. 
    # In general, you shouldn't have to worry about it.
    #
    # Example:
    #  irb(main):001:0> require 'ktools'
    #  => true
    #  irb(main):002:0> r, w = IO.pipe
    #  => [#<IO:0x4fa90c>, #<IO:0x4fa880>]
    #  irb(main):003:0> kq = Kqueue.new
    #  => #<Kernel::Kqueue:0x4f43a4 @kqfd=6, @fds={}>
    #  irb(main):004:0> kq.add(:socket, r, :events => [:read, :write])
    #  => true
    #  irb(main):005:0> kq.poll
    #  => []
    #  irb(main):006:0> w.write "foo"
    #  => 3
    #  irb(main):007:0> kq.poll
    #  => [{:type=>:socket, :target=>#<IO:0x4fa90c>, :events=>[:read]}]
    #  irb(main):008:0> [r, w, kq].each {|i| i.close}
    def add_socket(target, options={})
      filters, flags = options.values_at :events, :flags
      flags = flags ? flags.inject(0){|m,i| m | KQ_FLAGS[i] } : EV_CLEAR
      filters = filters ? filters.inject(0){|m,i| m | KQ_FILTERS[i] } : EVFILT_READ | EVFILT_WRITE
      fdnum = target.respond_to?(:fileno) ? target.fileno : target

      k = Kevent.new
      ev_set(k, fdnum, filters, EV_ADD | flags, 0, 0, nil)

      if kevent(@kqfd.fileno, k, 1, nil, 0, nil) == -1
        return false
      else
        @fds[fdnum] = {:target => target, :event => k}
        return true
      end
    end

    # Add events for a process. Takes a process id and and options hash. Supported events are:
    # * :exit - The process has exited
    # * :fork - The process has created a child process via fork(2) or similar call.
    # * :exec - The process executed a new process via execve(2) or similar call.
    # * :signal - The process was sent a signal. Status can be checked via waitpid(2) or similar call.
    # * :reap - The process was reaped by the parent via wait(2) or similar call.\
    #
    # Note: SIGNAL and REAP do not appear to exist in OSX older than Leopard.
    #
    # Example:
    #  irb(main):001:0> require 'ktools'
    #  => true
    #  irb(main):002:0> kq = Kqueue.new
    #  => #<Kernel::Kqueue:0x14f55b4 @kqfd=4, @pids={}, @fds={}>
    #  irb(main):003:0> fpid = fork{ sleep } 
    #  => 616
    #  irb(main):004:0> kq.add(:process, fpid, :events => [:exit])
    #  => true
    #  irb(main):005:0> Process.kill('TERM', fpid)
    #  => 1
    #  irb(main):006:0> kq.poll.first
    #  => {:events=>[:exit], :type=>:process, :target=>616}
    #
    def add_process(pid, options={})
      flags, fflags = options.values_at :flags, :events
      flags = flags ? flags.inject(0){|m,i| m | KQ_FLAGS[i] } : EV_CLEAR
      fflags = fflags.inject(0){|m,i| m | KQ_FFLAGS[i] }

      k = Kevent.new
      ev_set(k, pid, EVFILT_PROC, EV_ADD | flags, fflags, 0, nil)

      if kevent(@kqfd.fileno, k, 1, nil, 0, nil) == -1
        return false
      else
        @pids[pid] = {:target => pid, :event => k}
        return true
      end
    end

    # Poll for an event. Pass an optional timeout float as number of seconds to wait for an event. Default is 0.0 (do not wait).
    #
    # Using a timeout will block the current thread for the duration of the timeout. We use select() on the kqueue descriptor and
    # then call kevent() with 0 timeout, instead of blocking the whole interpreter with kevent().
    #
    # This call returns an array of hashes, similar to the following:
    #  => [{:type=>:socket, :target=>#<IO:0x4fa90c>, :events=>[:read]}]
    #
    # * :type - will be the type of event target, i.e. an event set with #add_file will have :type => :file
    # * :target - the 'target' or 'subject' of the event. This can be a File, IO, process or signal number.
    # * :event - the event that occurred on the target. This is one or more of the symbols you passed as :events => [:foo] when adding the event.
    def poll(timeout=0.0)
      ary = FFI::MemoryPointer.new(Kevent, 1024)

      r, w, e = IO.select([@kqfd], nil, nil, timeout)

      if r.nil? || r.empty?
        return []
      else
        case (count = kevent(@kqfd.fileno, nil, 0, ary, 1024, nil))
        when -1
          [errno]
        when 0
          []
        else
          res = []
          count.times{|i| res << process_event(Kevent.new(ary[i]))}
          res
        end
      end
    end

    def process_event(k) #:nodoc:
      res = case k[:filter]
      when EVFILT_VNODE
        h = @fds[k[:ident]]
        return nil if h.nil?
        events = []
        events << :delete if k[:fflags] & NOTE_DELETE == NOTE_DELETE
        events << :write if k[:fflags] & NOTE_WRITE == NOTE_WRITE
        events << :extend if k[:fflags] & NOTE_EXTEND == NOTE_EXTEND
        events << :attrib if k[:fflags] & NOTE_ATTRIB == NOTE_ATTRIB
        events << :link if k[:fflags] & NOTE_LINK == NOTE_LINK
        events << :rename if k[:fflags] & NOTE_RENAME == NOTE_RENAME
        events << :revoke if k[:fflags] & NOTE_REVOKE == NOTE_REVOKE
        delete(:file, k[:ident]) if events.include?(:delete) || events.include?(:revoke)
        {:target => h[:target], :type => :file, :events => events}
      when EVFILT_READ
        h = @fds[k[:ident]]
        return nil if h.nil?
        {:target => h[:target], :type => :socket, :events => [:read]}
      when EVFILT_WRITE
        h = @fds[k[:ident]]
        return nil if h.nil?
        {:target => h[:target], :type => :socket, :events => [:write]}
      when EVFILT_PROC
        h = @pids[k[:ident]]
        return nil if h.nil?
        events = []
        events << :exit if k[:fflags] & NOTE_EXIT == NOTE_EXIT
        events << :fork if k[:fflags] & NOTE_FORK == NOTE_FORK
        events << :exec if k[:fflags] & NOTE_EXEC == NOTE_EXEC
        events << :signal if Kqueue.const_defined?("NOTE_SIGNAL") and k[:fflags] & NOTE_SIGNAL == NOTE_SIGNAL
        events << :reap if Kqueue.const_defined?("NOTE_REAP") and k[:fflags] & NOTE_REAP == NOTE_REAP
        delete(:process, k[:ident]) if events.include?(:exit)
        {:target => h[:target], :type => :process, :events => events}
      end

      delete(res[:type], res[:target]) if k[:flags] & EV_ONESHOT == EV_ONESHOT
      res
    end

    # Stop generating events for the given type and event target, ie:
    #  kq.delete(:process, 6244)
    def delete(type, target)
      ident = target.respond_to?(:fileno) ? target.fileno : target
      container = case type
      when :socket
        @fds
      when :file
        @fds
      when :process
        @pids
      end
      h = container[ident]
      return false if h.nil?
      k = h[:event]
      ev_set(k, k[:ident], k[:filter], EV_DELETE, k[:fflags], 0, nil)
      kevent(@kqfd.fileno, k, 1, nil, 0, nil)
      container.delete(ident)
      return true
    end

    # Close the kqueue descriptor. This essentially shuts down your kqueue and renders all active events on this kqueue removed. 
    def close
      @kqfd.close
    end

  end
end
