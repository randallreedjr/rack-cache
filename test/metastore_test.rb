require "#{File.dirname(__FILE__)}/spec_setup"
require 'rack/cache/metastore'

describe_shared 'A Rack::Cache::MetaStore Implementation' do

  before do
    @request = mock_request('/', {})
    @response = mock_response(200, {}, ['hello world'])
    @entity_store = nil
  end
  after do
    @store = nil
    @entity_store = nil
  end

  # Low-level implementation methods ===========================================

  it 'writes a list of negotation tuples with #write' do
    lambda { @store.write('/test', [[{}, {}]]) }.should.not.raise
  end

  it 'reads a list of negotation tuples with #read' do
    @store.write('/test', [[{},{}],[{},{}]])
    tuples = @store.read('/test')
    tuples.should.be == [ [{},{}], [{},{}] ]
  end

  it 'reads an empty list with #read when nothing cached at key' do
    @store.read('/nothing').should.be.empty
  end

  it 'removes entries for key with #purge' do
    @store.write('/test', [[{},{}]])
    @store.read('/test').should.not.be.empty

    @store.purge('/test')
    @store.read('/test').should.be.empty
  end

  it 'succeeds when purging non-existing entries' do
    @store.read('/test').should.be.empty
    @store.purge('/test')
  end

  it 'returns nil from #purge' do
    @store.write('/test', [[{},{}]])
    @store.purge('/test').should.be nil
    @store.read('/test').should.be == []
  end

  %w[/test http://example.com:8080/ /test?x=y /test?x=y&p=q].each do |key|
    it "can read and write key: '#{key}'" do
      lambda { @store.write(key, [[{},{}]]) }.should.not.raise
      @store.read(key).should.be == [[{},{}]]
    end
  end

  it "can read and write fairly large keys" do
    key = "b" * 4096
    lambda { @store.write(key, [[{},{}]]) }.should.not.raise
    @store.read(key).should.be == [[{},{}]]
  end

  # Abstract methods ===========================================================

  define_method :store_simple_entry do
    @request = mock_request('/test', {})
    @response = mock_response(200, {'Cache-Control' => 'max-age=420'}, ['test'])
    body = @response.body
    @store.store(@request, @response, @entity_store)
    @response.body.should.not.be body
  end

  it 'stores a cache entry' do
    store_simple_entry
    @store.read('/test').should.not.be.empty
  end

  it 'sets the X-Content-Digest response header before storing' do
    store_simple_entry
    req, res = @store.read('/test').first
    res['X-Content-Digest'].should.be == 'a94a8fe5ccb19ba61c4c0873d391e987982fbbd3'
  end

  it 'finds a stored entry with #lookup' do
    store_simple_entry
    response = @store.lookup(@request, @entity_store)
    response.should.not.be.nil
    response.should.be.kind_of Rack::Cache::Response
  end

  it 'restores response headers properly with #lookup' do
    store_simple_entry
    response = @store.lookup(@request, @entity_store)
    response.headers.reject{|k,v| k =~ /^X-/}.
      should.be == @response.headers.merge('Age' => '0', 'Content-Length' => '4')
  end

  it 'restores response body from entity store with #lookup' do
    store_simple_entry
    response = @store.lookup(@request, @entity_store)
    body = '' ; response.body.each {|p| body << p}
    body.should.be == 'test'
  end

  # Vary =======================================================================

  it 'does not return entries that Vary with #lookup' do
    req1 = mock_request('/test', {'HTTP_FOO' => 'Foo', 'HTTP_BAR' => 'Bar'})
    req2 = mock_request('/test', {'HTTP_FOO' => 'Bling', 'HTTP_BAR' => 'Bam'})
    res = mock_response(200, {'Vary' => 'Foo Bar'}, ['test'])
    @store.store(req1, res, @entity_store)

    @store.lookup(req2, @entity_store).should.be.nil
  end

  it 'stores multiple responses for each Vary combination' do
    req1 = mock_request('/test', {'HTTP_FOO' => 'Foo',   'HTTP_BAR' => 'Bar'})
    res1 = mock_response(200, {'Vary' => 'Foo Bar'}, ['test 1'])
    @store.store(req1, res1, @entity_store)

    req2 = mock_request('/test', {'HTTP_FOO' => 'Bling', 'HTTP_BAR' => 'Bam'})
    res2 = mock_response(200, {'Vary' => 'Foo Bar'}, ['test 2'])
    @store.store(req2, res2, @entity_store)

    req3 = mock_request('/test', {'HTTP_FOO' => 'Baz',   'HTTP_BAR' => 'Boom'})
    res3 = mock_response(200, {'Vary' => 'Foo Bar'}, ['test 3'])
    @store.store(req3, res3, @entity_store)

    slurp(@store.lookup(req3, @entity_store).body).should.be == 'test 3'
    slurp(@store.lookup(req1, @entity_store).body).should.be == 'test 1'
    slurp(@store.lookup(req2, @entity_store).body).should.be == 'test 2'

    @store.read('/test').length.should.be == 3
  end

  it 'overwrites non-varying responses with #store' do
    req1 = mock_request('/test', {'HTTP_FOO' => 'Foo',   'HTTP_BAR' => 'Bar'})
    res1 = mock_response(200, {'Vary' => 'Foo Bar'}, ['test 1'])
    @store.store(req1, res1, @entity_store)
    slurp(@store.lookup(req1, @entity_store).body).should.be == 'test 1'

    req2 = mock_request('/test', {'HTTP_FOO' => 'Bling', 'HTTP_BAR' => 'Bam'})
    res2 = mock_response(200, {'Vary' => 'Foo Bar'}, ['test 2'])
    @store.store(req2, res2, @entity_store)
    slurp(@store.lookup(req2, @entity_store).body).should.be == 'test 2'

    req3 = mock_request('/test', {'HTTP_FOO' => 'Foo',   'HTTP_BAR' => 'Bar'})
    res3 = mock_response(200, {'Vary' => 'Foo Bar'}, ['test 3'])
    @store.store(req3, res3, @entity_store)
    slurp(@store.lookup(req1, @entity_store).body).should.be == 'test 3'

    @store.read('/test').length.should.be == 2
  end

  # Helper Methods =============================================================

  define_method :mock_request do |uri,opts|
    env = Rack::MockRequest.env_for(uri, opts || {})
    Rack::Cache::Request.new(env)
  end

  define_method :mock_response do |status,headers,body|
    headers ||= {}
    body = Array(body).compact
    Rack::Cache::Response.new(status, headers, body)
  end

  define_method :slurp do |body|
    buf = ''
    body.each {|part| buf << part }
    buf
  end

end


describe 'Rack::Cache::MetaStore' do
  describe 'Heap' do
    it_should_behave_like 'A Rack::Cache::MetaStore Implementation'
    before do
      @store = Rack::Cache::MetaStore::Heap.new
      @entity_store = Rack::Cache::EntityStore::Heap.new
    end
  end

  describe 'Disk' do
    it_should_behave_like 'A Rack::Cache::MetaStore Implementation'
    before do
      @temp_dir = create_temp_directory
      @store = Rack::Cache::MetaStore::Disk.new("#{@temp_dir}/meta")
      @entity_store = Rack::Cache::EntityStore::Disk.new("#{@temp_dir}/entity")
    end
    after do
      remove_entry_secure @temp_dir
    end
  end

  need_memcached 'metastore tests' do
    describe 'MemCache' do
      it_should_behave_like 'A Rack::Cache::MetaStore Implementation'
      before :each do
        @temp_dir = create_temp_directory
        $memcached.flush
        @store = Rack::Cache::MetaStore::MemCache.new($memcached)
        @entity_store = Rack::Cache::EntityStore::Heap.new
      end
    end
  end
end
