# Copyright:: Copyright (c) 2008 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

Thread.abort_on_exception = true

require 'rubygems'
require 'spec/expectations'

CHEF_PROJECT_ROOT = File.expand_path(File.dirname(__FILE__) + '/../../')
KNIFE_CONFIG = CHEF_PROJECT_ROOT + '/features/data/config/knife.rb'
KNIFE_CMD = File.expand_path(File.join(CHEF_PROJECT_ROOT, "chef", "bin", "knife"))
FEATURES_DATA = File.join(CHEF_PROJECT_ROOT, "features", "data")
INTEGRATION_COOKBOOKS = File.join(FEATURES_DATA, "cookbooks")

$:.unshift(CHEF_PROJECT_ROOT + '/chef/lib')
$:.unshift(CHEF_PROJECT_ROOT + '/chef-server-api/lib')
$:.unshift(CHEF_PROJECT_ROOT + '/chef-server-webui/lib')
$:.unshift(CHEF_PROJECT_ROOT + '/chef-solr/lib')

require 'chef'
require 'chef/config'
require 'chef/client'
require 'chef/data_bag'
require 'chef/data_bag_item'
require 'chef/api_client'
require 'chef/checksum'
require 'chef/sandbox'
require 'chef/solr'
require 'chef/certificate'
require 'chef/mixin/shell_out'
require 'tmpdir'
require 'chef/streaming_cookbook_uploader'
require 'webrick'
require 'restclient'

include Chef::Mixin::ShellOut

Ohai::Config[:disabled_plugins] << 'darwin::system_profiler' << 'darwin::kernel' << 'darwin::ssh_host_key' << 'network_listeners'
Ohai::Config[:disabled_plugins ]<< 'darwin::uptime' << 'darwin::filesystem' << 'dmi' << 'lanuages' << 'perl' << 'python' << 'java'

ENV['LOG_LEVEL'] ||= 'error'

def setup_logging
  Chef::Config.from_file(File.join(File.dirname(__FILE__), '..', 'data', 'config', 'server.rb'))
  if ENV['DEBUG'] == 'true' || ENV['LOG_LEVEL'] == 'debug'
    Chef::Config[:log_level] = :debug
    Chef::Log.level = :debug
  else
    Chef::Config[:log_level] = ENV['LOG_LEVEL'].to_sym 
    Chef::Log.level = ENV['LOG_LEVEL'].to_sym
  end
  Ohai::Log.logger = Chef::Log.logger 
end

def delete_databases
  c = Chef::REST.new(Chef::Config[:couchdb_url], nil, nil)
  %w{chef_integration chef_integration_safe}.each do |db|
    begin
      c.delete_rest("#{db}/")
    rescue
    end
  end
end

def create_databases
  Chef::Log.info("Creating bootstrap databases")
  cdb = Chef::CouchDB.new(Chef::Config[:couchdb_url], "chef_integration")
  cdb.create_db
  cdb.create_id_map
  Chef::Node.create_design_document
  Chef::Role.create_design_document
  Chef::DataBag.create_design_document
  Chef::ApiClient.create_design_document
  Chef::CookbookVersion.create_design_document
  Chef::Sandbox.create_design_document
  Chef::Checksum.create_design_document
  
  Chef::Role.sync_from_disk_to_couchdb
  Chef::Certificate.generate_signing_ca
  Chef::Certificate.gen_validation_key
  Chef::Certificate.gen_validation_key(Chef::Config[:web_ui_client_name], Chef::Config[:web_ui_key])
  system("cp #{File.join(Dir.tmpdir, "chef_integration", "validation.pem")} #{Dir.tmpdir}")
  system("cp #{File.join(Dir.tmpdir, "chef_integration", "webui.pem")} #{Dir.tmpdir}")

  cmd = [KNIFE_CMD, "cookbook", "upload", "-a", "-o", INTEGRATION_COOKBOOKS, "-u", "validator", "-k", File.join(Dir.tmpdir, "validation.pem"), "-c", KNIFE_CONFIG]
  Chef::Log.info("Uploading fixture cookbooks with #{cmd.join(' ')}")
  cmd << {:timeout => 120}
  shell_out!(*cmd)
end

# Bulk GET all documents in the given db, using the given page size.
# Calls the required block for each page size, passing in an array of
# rows.
def bulk_get_paged(chef_rest, db, page_size)
  last_key = nil

  paged_rows = nil
  until (paged_rows && paged_rows.length == 0) do
    url = "#{db}/_all_docs?limit=100&include_docs=true"
    if last_key
      url += "&startkey=#{CGI.escape(last_key.to_json)}&skip=1"
    end
    #puts "replicate_manually: url = #{url}"
    
    paged_results = chef_rest.get_rest(url)
    paged_rows = paged_results['rows']

    if paged_rows.length > 0
      yield paged_rows
      last_key = paged_rows.last['key']
    end
  end
end

# Replicate a (set of) source databases to a (set of) target databases. Uses
# manual bulk GET/POST as Couch's internal _replicate endpoint crashes and
# starts to time out after some number of runs.
def replicate_dbs(replication_specs, delete_source_dbs = false)
  replication_specs = [replication_specs].flatten
  
  Chef::Log.debug "replicate_dbs: replication_specs = #{replication_specs.inspect}, delete_source_dbs = #{delete_source_dbs}"
  
  chef_rest = Chef::REST.new(Chef::Config[:couchdb_url], nil, nil)
  replication_specs.each do |spec|
    source_db = spec[:source_db]
    target_db = spec[:target_db]

    # Delete and re-create the target db
    begin
      Chef::Log.debug("Deleting #{target_db}, if exists")
      chef_rest.delete_rest("#{target_db}")
    rescue Net::HTTPServerException => e
      raise unless e.message =~ /Not Found/
    end
    Chef::Log.debug("Creating #{target_db}")
    chef_rest.put_rest(target_db, nil)

    Chef::Log.debug("Replicating #{source_db} to #{target_db} using bulk (batch) method")
    bulk_get_paged(chef_rest, source_db, 100) do |paged_rows|
      #puts "incoming paged_rows is #{paged_rows.inspect}"
      paged_rows = paged_rows.map do |row|
        doc_in_row = row['doc']
        doc_in_row.delete '_rev'
        doc_in_row
      end

      #puts "now, paged_rows is #{paged_rows.inspect}"
      #pp({:_PAGED_ROWS => paged_rows})

      chef_rest.post_rest("#{target_db}/_bulk_docs", {"docs" => paged_rows})
    end

    # Delete the source if asked to..
    if delete_source_dbs
      Chef::Log.debug("Deleting #{source_db}")
      c.delete_rest(source_db)
    end
  end
end

def prepare_replicas
  replicate_dbs({ :source_db => "#{Chef::Config[:couchdb_url]}/chef_integration", :target_db => "#{Chef::Config[:couchdb_url]}/chef_integration_safe" })
end

def cleanup
  if File.exists?(Chef::Config[:validation_key])
    File.unlink(Chef::Config[:validation_key])
  end
  if File.exists?(Chef::Config[:web_ui_key])
    File.unlink(Chef::Config[:web_ui_key])
  end
end

###
# Pre-testing setup
###
setup_logging
cleanup
delete_databases
create_databases
prepare_replicas

Chef::Log.info("Ready to run tests")

###
# The Cucumber World
###
module ChefWorld

  attr_accessor :recipe, :cookbook, :api_response, :inflated_response, :log_level,
                :chef_args, :config_file, :stdout, :stderr, :status, :exception,
                :gemserver_thread, :sandbox_url

  def self.ohai
    # ohai takes a while, so only ever run it once.
    @ohai ||= begin
      o = Ohai::System.new
      o.all_plugins
      o
    end
  end

  def ohai
    ChefWorld.ohai
  end

  def client
    @client ||= begin
      c = Chef::Client.new
      c.ohai = ohai
      c
    end
  end

  def rest
    @rest ||= Chef::REST.new('http://localhost:4000', nil, nil)
  end

  def tmpdir
    @tmpdir ||= File.join(Dir.tmpdir, "chef_integration")
  end

  def server_tmpdir
    @server_tmpdir ||= File.expand_path(File.join(datadir, "tmp"))
  end
  
  def datadir
    @datadir ||= File.join(File.dirname(__FILE__), "..", "data")
  end

  def configdir
    @configdir ||= File.join(File.dirname(__FILE__), "..", "data", "config")
  end

  def cleanup_files
    @cleanup_files ||= Array.new
  end

  def cleanup_dirs
    @cleanup_dirs ||= Array.new
  end

  def stash
    @stash ||= Hash.new
  end
  
  def gemserver
    @gemserver ||= WEBrick::HTTPServer.new(
      :Port         => 8000,
      :DocumentRoot => datadir + "/gems/",
      # Make WEBrick STFU
      :Logger       => Logger.new(StringIO.new),
      :AccessLog    => [ StringIO.new, WEBrick::AccessLog::COMMON_LOG_FORMAT ]
    )
  end

  attr_accessor :apt_server_thread

  def apt_server
    @apt_server ||= WEBrick::HTTPServer.new(
      :Port         => 9000,
      :DocumentRoot => datadir + "/apt/var/www/apt",
      # Make WEBrick STFU
      :Logger       => Logger.new(StringIO.new),
      :AccessLog    => [ StringIO.new, WEBrick::AccessLog::COMMON_LOG_FORMAT ]
    )
  end

  def make_admin
    admin_client
    @rest = Chef::REST.new(Chef::Config[:registration_url], 'bobo', "#{tmpdir}/bobo.pem")
    #Chef::Config[:client_key] = "#{tmpdir}/bobo.pem"
    #Chef::Config[:node_name] = "bobo"
  end
  
  def admin_rest
    admin_client
    @admin_rest ||= Chef::REST.new(Chef::Config[:registration_url], 'bobo', "#{tmpdir}/bobo.pem")
  end
  
  def admin_client
    unless @admin_client
      r = Chef::REST.new(Chef::Config[:registration_url], Chef::Config[:validation_client_name], Chef::Config[:validation_key])
      r.register("bobo", "#{tmpdir}/bobo.pem")
      c = Chef::ApiClient.cdb_load("bobo")
      c.admin(true)
      c.cdb_save
      @admin_client = c
    end
  end
  
  def make_non_admin
    r = Chef::REST.new(Chef::Config[:registration_url], Chef::Config[:validation_client_name], Chef::Config[:validation_key])
    r.register("not_admin", "#{tmpdir}/not_admin.pem")
    c = Chef::ApiClient.cdb_load("not_admin")
    c.cdb_save
    @rest = Chef::REST.new(Chef::Config[:registration_url], 'not_admin', "#{tmpdir}/not_admin.pem")
    #Chef::Config[:client_key] = "#{tmpdir}/not_admin.pem"
    #Chef::Config[:node_name] = "not_admin"
  end
  
end

World(ChefWorld)

Before do
  system("mkdir -p #{tmpdir}")
  system("cp -r #{File.join(Dir.tmpdir, "validation.pem")} #{File.join(tmpdir, "validation.pem")}")
  system("cp -r #{File.join(Dir.tmpdir, "webui.pem")} #{File.join(tmpdir, "webui.pem")}")
  
  replicate_dbs({:source_db => "#{Chef::Config[:couchdb_url]}/chef_integration_safe",
                 :target_db => "#{Chef::Config[:couchdb_url]}/chef_integration"})
end

After do
  s = Chef::Solr.new
  s.solr_delete_by_query("*:*")
  s.solr_commit
  gemserver.shutdown
  gemserver_thread && gemserver_thread.join

  apt_server.shutdown
  apt_server_thread && apt_server_thread.join

  cleanup_files.each do |file|
    system("rm #{file}")
  end
  cleanup_dirs.each do |dir|
    system("rm -rf #{dir}")
  end
  cj = Chef::REST::CookieJar.instance
  cj.keys.each do |key|
    cj.delete(key)
  end
  data_tmp = File.join(File.dirname(__FILE__), "..", "data", "tmp")
  system("rm -rf #{data_tmp}/*")
  system("rm -rf #{tmpdir}")
end
