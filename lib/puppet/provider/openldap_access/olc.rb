require File.expand_path(File.join(File.dirname(__FILE__), %w[.. openldap]))
require 'tempfile'

# rubocop:disable Style/VariableName
# rubocop:disable Style/MethodName
# rubocop:disable Lint/AssignmentInCondition
Puppet::Type.
  type(:openldap_access).
  provide(:olc, parent: Puppet::Provider::Openldap) do

  # TODO: Use ruby bindings (can't find one that support IPC)

  defaultfor osfamily: [:debian, :freebsd, :redhat, :suse]

  mk_resource_methods

  def self.instances
    # TODO: restict to bdb, hdb and globals
    i = []
    slapcat('(olcAccess=*)').split("\n\n").map do |paragraph|
      access = nil
      suffix = nil
      position = nil
      paragraph.gsub("\n ", '').split("\n").map do |line|
        case line
        when %r{^olcDatabase: }
          suffix = "cn=#{line.split(' ')[1].gsub(%r{\{-?\d+\}}, '')}"
        when %r{^olcSuffix: }
          suffix = line.split(' ')[1]
        when %r{^olcAccess: }
          begin
            position, what, bys = line.match(%r{^olcAccess:\s+\{(\d+)\}to\s+(\S+(?:\s+filter=\S+)?(?:\s+attrs=\S+)?(?:\s+val=\S+)?)(\s+by\s+.*)+$}).captures
          rescue
            raise Puppet::Error, "Failed to parse olcAccess for suffix '#{suffix}': #{line}"
          end
          access = []
          bys.split(%r{(?= by .+)}).each do |b|
            access << b.lstrip
          end
          i << new(
            name: "#{position} on #{suffix}",
            ensure: :present,
            position: position,
            what: what,
            access: access,
            suffix: suffix,
          )
        end
      end
    end

    i
  end

  def self.prefetch(resources)
    accesses = instances
    resources.keys.each do |name|
      if provider = accesses.find do |access|
        if resources[name][:position]
          access.suffix == resources[name][:suffix] &&
          access.position == resources[name][:position].to_s
        else
          access.suffix == resources[name][:suffix] &&
          access.access.flatten == resources[name][:access].flatten &&
          access.what == resources[name][:what]
        end
      end
        resources[name].provider = provider
      end
    end
  end

  def self.getDn(suffix)
    if suffix == 'cn=frontend'
      'olcDatabase={-1}frontend,cn=config'
    elsif suffix == 'cn=config'
      'olcDatabase={0}config,cn=config'
    elsif suffix == 'cn=monitor'
      slapcat('(olcDatabase=monitor)').split("\n").map do |line|
        return line.split(' ')[1] if line =~ %r{^dn: }
      end
    else
      slapcat("(olcSuffix=#{suffix})").split("\n").map do |line|
        return line.split(' ')[1] if line =~ %r{^dn: }
      end
    end
  end

  def getDn(*args)
    self.class.getDn(*args)
  end

  def exists?
    @property_hash[:ensure] == :present
  end

  def create
    t = Tempfile.new('openldap_access')
    t << "dn: #{getDn(resource[:suffix])}\n"
    t << "add: olcAccess\n"
    t << if resource[:position]
           "olcAccess: {#{resource[:position]}}to #{resource[:what]}\n"
         else
           "olcAccess: to #{resource[:what]}\n"
         end
    resource[:access].flatten.each do |a|
      t << "  #{a}\n"
    end
    t.close
    Puppet.debug(IO.read(t.path))
    begin
      ldapmodify(t.path)
    rescue StandardError => e
      raise Puppet::Error, "LDIF content:\n#{IO.read t.path}\nError message: #{e.message}"
    end
  end

  def destroy
    t = Tempfile.new('openldap_access')
    t << "dn: #{getDn(@property_hash[:suffix])}\n"
    t << "changetype: modify\n"
    t << "delete: olcAccess\n"
    t << "olcAccess: {#{@property_hash[:position]}}\n"
    t.close
    Puppet.debug(IO.read(t.path))
    begin
      ldapmodify(t.path)
    rescue StandardError => e
      raise Puppet::Error, "LDIF content:\n#{IO.read t.path}\nError message: #{e.message}"
    end
  end

  def initialize(value = {})
    super(value)
    @property_flush = {}
  end

  def access=(value)
    @property_flush[:access] = value.flatten
  end

  def self.getCountOfOlcAccess(suffix)
    countOfElement = 0
    slapcat('(olcAccess=*)', getDn(suffix).to_s).split("\n\n").map do |paragraph|
      paragraph.gsub("\n ", '').split("\n").map do |line|
        case line
        when %r{^olcAccess: }
          countOfElement += 1
        end
      end
    end
    countOfElement
  end

  def getCurrentOlcAccess(suffix)
    i = []
    slapcat('(olcAccess=*)', getDn(suffix).to_s).split("\n\n").map do |paragraph|
      paragraph.gsub("\n ", '').split("\n").map do |line|
        case line
        when %r{^olcAccess: }
          position, content = line.match(%r{^olcAccess:\s+\{(\d+)\}(.*)$}).captures
          i << {
            position: position,
            content: content,
          }
        end
      end
    end
    i
  end

  def flush
    unless @property_flush.empty?
      current_olcAccess = getCurrentOlcAccess(resource[:suffix])
      t = Tempfile.new('openldap_access')
      t << "dn: #{getDn(resource[:suffix])}\n"
      t << "changetype: modify\n"
      t << "replace: olcAccess\n"
      position = resource[:position] || @property_hash[:position]
      current_olcAccess.each do |olcAccess|
        if olcAccess[:position].to_i == position.to_i
          t << "olcAccess: {#{position}}to #{resource[:what]}\n"
          resource[:access].flatten.each do |a|
            t << "  #{a}\n"
          end
        else
          t << "olcAccess: {#{olcAccess[:position]}}#{olcAccess[:content]}\n"
        end
      end
      countOfElement = self.class.getCountOfOlcAccess(resource[:suffix])
      t.close
      Puppet.debug(IO.read(t.path))
      begin
        ldapmodify(t.path)
      rescue StandardError => e
        raise Puppet::Error, "LDIF content:\n#{IO.read t.path}\nError message: #{e.message}"
      end
    end
    @property_hash = resource.to_hash
  end
end
