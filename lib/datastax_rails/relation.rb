require 'rsolr'
require 'pp' if ENV['DEBUG_SOLR'] == 'true'

module DatastaxRails
  class Relation
    MULTI_VALUE_METHODS = [:order, :where, :where_not, :fulltext, :greater_than, :less_than, :select, :stats, :field_facet, :range_facet, :slow_order]
    SINGLE_VALUE_METHODS = [:page, :per_page, :reverse_order, :query_parser, :consistency, :ttl, :use_solr, :escape, :group, :allow_filtering]
    
    SOLR_CHAR_RX = /([\+\!\(\)\[\]\^\"\~\:\'\=\/]+)/
    
    Relation::MULTI_VALUE_METHODS.each do |m|
      attr_accessor :"#{m}_values"
    end
    Relation::SINGLE_VALUE_METHODS.each do |m|
      attr_accessor :"#{m}_value"
    end
    attr_accessor :create_with_value, :default_scoped
    attr_accessor :highlight_options
    
    include SearchMethods
    include ModificationMethods
    include FinderMethods
    include SpawnMethods
    include StatsMethods
    include Batches
    include FacetMethods
    
    attr_reader :klass, :column_family, :loaded, :cql
    alias :loaded? :loaded
    alias :default_scoped? :default_scoped
    
    # Initializes the Relation.  Defaults page value to 1, per_page to the class
    # default, and solr use to true.  Everything else gets defaulted to nil or
    # empty.
    #
    # @param [Class] klass the child of DatastaxRails::Base that this relation searches
    # @param [String, Symbol] column_family the name of the column family this relation searches
    def initialize(klass, column_family)
      @klass, @column_family = klass, column_family
      @loaded = false
      @results = []
      @default_scoped = false
      @cql = DatastaxRails::Cql.for_class(klass)
      
      SINGLE_VALUE_METHODS.each {|v| instance_variable_set(:"@#{v}_value", nil)}
      MULTI_VALUE_METHODS.each {|v| instance_variable_set(:"@#{v}_values", [])}
      @highlight_options = {}
      @per_page_value = @klass.default_page_size
      @page_value = 1
      @use_solr_value = :default
      @extensions = []
      @create_with_value = {}
      @escape_value = :default
      @stats = {}
    end
    
    # Returns true if the two relations have the same query parameters
    def ==(other)
      case other
      when Relation
        # This is not a valid implementation.  It's a placeholder till I figure out the right way.
        MULTI_VALUE_METHODS.each do |m|
          return false unless other.send("#{m}_values") == self.send("#{m}_values")
        end
        SINGLE_VALUE_METHODS.each do |m|
          return false unless other.send("#{m}_value") == self.send("#{m}_value")
        end
        return true
      when Array
        to_a == other
      end
    end
    
    # Returns true if there are any results given the current criteria
    def any?
      if block_given?
        to_a.any? { |*block_args| yield(*block_args) }
      else
        !empty?
      end
    end
    alias :exists? :any?
    
    # Returns the total number of entries that match the given search.
    # This means the total number of matches regardless of page size.
    # If the relation has not been populated yet, a limit of 1 will be
    # placed on the query before it is executed.
    #
    # For a grouped query, this still returns the total number of 
    # matching documents
    #
    # Compare with #size.
    def count
      @count ||= (with_default_scope.path_decision == :solr) ? with_default_scope.count_via_solr : with_default_scope.count_via_cql
    end
    
    def stats
      unless(loaded?)
        to_a
      end
      @stats
    end
    
    # Returns the current page for will_paginate compatibility
    def current_page
      self.page_value.try(:to_i)
    end
    
    # current_page - 1 or nil if there is no previous page
    def previous_page
      current_page > 1 ? (current_page - 1) : nil
    end

    # current_page + 1 or nil if there is no next page
    def next_page
      current_page < total_pages ? (current_page + 1) : nil
    end
    
    # Gets a default scope with no conditions or search attributes set.
    def default_scope
      klass.scoped.with_default_scope
    end
    
    def with_default_scope #:nodoc:
      if default_scoped? && default_scope = klass.send(:build_default_scope)
        default_scope = default_scope.merge(self)
        default_scope.default_scoped = false
        default_scope
      else
        self
      end
    end
    
    # Returns true if there are no results given the current criteria
    def empty?
      return @results.empty? if loaded?
      
      c = count
      c.respond_to?(:zero?) ? c.zero? : c.empty?
    end
    
    # Returns true if there are multiple results given the current criteria
    def many?
      if block_given?
        to_a.many? { |*block_args| yield(*block_args) }
      else
        count > 1
      end
    end
    
    # Constructs a new instance of the class this relation points to with
    # any criteria from this relation applied
    def new(*args, &block)
      scoping { @klass.new(*args, &block) }
    end
    
    # Reloads the results from cassandra or solr as appropriate
    def reload
      reset
      to_a
      self
    end
    
    # Empties out the current results.  The next call to to_a
    # will re-run the query.
    def reset
      @loaded = @first = @last = @scope_for_create = @count = nil
      @stats = {}
      @results = []
    end
    
    # Copies will have changes made to the criteria and so need to be reset.
    def initialize_copy(other)
      reset
      @search = nil
    end
    
    # Performs a deep copy using Marshal when cloning.
    def clone
      dup.tap do |r|
        MULTI_VALUE_METHODS.each do |m|
          begin
            r.send("#{m}_values=", Marshal.load(Marshal.dump(self.send("#{m}_values"))))
          rescue
            r.send("#{m}_values=", self.send("#{m}_values").dup)
          end
        end
        SINGLE_VALUE_METHODS.each do |m|
          begin
            r.send("#{m}_value=", Marshal.load(Marshal.dump(self.send("#{m}_value")))) if self.send("#{m}_value")
          rescue
            r.send("#{m}_value=", self.send("#{m}_value").dup) if self.send("#{m}_value")
          end
        end
      end
    end
    
    # Returns the size of the total result set for the given criteria
    # NOTE that this takes pagination into account so will only return
    # the number of results in the current page.  DatastaxRails models
    # can have a +default_page_size+ set which will cause them to be
    # paginated all the time.
    #
    # For a grouped query, this returns the size of the largest group.
    #
    # Compare with #count
    def size
      return @results.size if loaded? && !@group_value
      total_entries = count
      (per_page_value && total_entries > per_page_value) ? per_page_value : total_entries
    end
    
    # Returns the total number of pages required to display the results
    # given the current page size.  Used by will_paginate.
    def total_pages
      return 1 unless @per_page_value
      (count / @per_page_value.to_f).ceil
    end
    
    # Actually executes the query if not already executed.
    # Returns a standard array thus no more methods may be chained.
    def to_a
      return @results if loaded?
      if with_default_scope.path_decision == :solr
        @results = with_default_scope.query_via_solr
        @count = @group_value ? @results.total_for_all : @results.total_entries
      else
        @results = with_default_scope.query_via_cql
      end
      @loaded = true
      @results
    end
    alias :all :to_a
    alias :results :to_a
    
    # Create a new object with all of the criteria from this relation applied
    def create(*args, &block)
      scoping { @klass.create(*args, &block) }
    end

    # Like +create+ but throws an exception on failure
    def create!(*args, &block)
      scoping { @klass.create!(*args, &block) }
    end
    
    # Override respond_to? so that it matches method_missing
    def respond_to?(method, include_private = false)
      Array.method_defined?(method)                       ||
      @klass.respond_to?(method, include_private)         ||
      super
    end
    
    def path_decision
      return :cassandra if klass <= DatastaxRails::CassandraOnlyModel
      case use_solr_value
      when false
        return :cassandra
      when true
        return :solr
      else
        # If we've already decided to use cassandra, just go with it.
        return :cassandra unless use_solr_value
        [order_values, where_not_values, fulltext_values, greater_than_values, less_than_values, field_facet_values,
         range_facet_values, group_value].each do |solr_only_stuff|
           return :solr unless solr_only_stuff.blank? 
         end
        return :solr unless group_value.blank?
        return :solr unless page_value == 1
        @where_values.each do |wv|
          wv.each do |k,v|
            next if [:id, :key].include?(k.to_sym)
            if(klass.attribute_definitions[k].indexed == :solr || !klass.attribute_definitions[k].indexed)
              return :solr
            end
          end
        end
        # If we get here, we can safely run this query via Cassandra
        return :cassandra
      end
    end
    
    # If we index something into both cassandra and solr, we rename the cassandra
    # column.  This method maps the column names as necessary
    def map_cassandra_columns(conditions)
      {}.tap do |mapped|
        conditions.each do |k,v|
          if(klass.attribute_definitions[k].indexed == :both)
            mapped["__#{k}"] = v
          else
            mapped[k] = v
          end
        end
      end
    end
    
    def count_via_cql
      cql = @cql.select(['count(*)'])
      cql.using(@consistency_value) if @consistency_value
      @where_values.each do |wv|
        cql.conditions(wv)
      end
      cql.allow_filtering if @allow_filtering_value
      CassandraCQL::Result.new(cql.execute).fetch['count']
    end
    
    # Constructs a CQL query and runs it against Cassandra directly.  For this to
    # work, you need to run against either the primary key or a secondary index.
    # For ad-hoc queries, you will have to use Solr.
    def query_via_cql
      select_columns = select_values.empty? ? (@klass.attribute_definitions.keys - @klass.lazy_attributes) : select_values.flatten
      cql = @cql.select((select_columns + @klass.key_factory.key_columns).collect(&:to_sym).uniq)
      cql.using(@consistency_value) if @consistency_value
      @where_values.each do |wv|
        cql.conditions(Hash[wv.map {|k,v| [(k.to_sym == :id ? klass.primary_key_name.to_sym : k), v]}])
      end
      @greater_than_values.each do |gtv|
        gtv.each do |k,v|
          # Special case if inequality is equal to the primary key (we're paginating)
          if(k.to_sym == klass.primary_key_name.to_sym)
            cql.paginate(v)
          end
        end
      end
      if(@per_page_value)
        cql.limit(@per_page_value)
      end
      cql.allow_filtering if @allow_filtering_value
      results = []
      begin
        CassandraCQL::Result.new(cql.execute).fetch do |row|
          results << @klass.instantiate(row[klass.primary_key_name.to_s], row.to_hash, select_columns)
        end
      rescue CassandraCQL::Error::InvalidRequestException => e
        # If we get an exception about an empty key, ignore it.  We'll return an empty set.
        if e.message =~ /Key may not be empty/
          # No-Op
        else
          raise
        end
      end
      if(@slow_order_values.any?)
        results.sort! do |a,b| 
          values = slow_ordering(a,b)
          values[0] <=> values[1]
        end
      end
      results
    end
    
    def slow_ordering(obj1, obj2)
      [[],[]].tap do |values|
        i=0
        @slow_order_values.each do |ordering|
          ordering.each do |k,v|
            if v == :asc
              values[0][i] = obj1.send(k)
              values[1][i] = obj2.send(k)
            else
              values[1][i] = obj1.send(k)
              values[0][i] = obj2.send(k)
            end
          end
          i += 1
        end
      end
    end
    
    # Runs the query with a limit of 1 just to grab the total results attribute off
    # the result set. 
    def count_via_solr
      results = limit(1).select(:id).to_a
      @group_value ? results.total_for_all : results.total_entries
    end
    
    # Escapes values that might otherwise mess up the URL or confuse SOLR.
    # If you want to handle escaping yourself for a particular query then
    # SearchMethods#dont_escape is what you're looking for.
    def solr_escape(str)
      if str.is_a?(String) && escape_value
        str.gsub(SOLR_CHAR_RX, '\\\\\1')
      else
        str
      end
    end
    
    def full_solr_range(attr)
      if(self.klass.attribute_definitions[attr])
        self.klass.attribute_definitions[attr].coder.full_solr_range
      else
        '[\"\" TO *]'
      end
    end
    
    # Constructs a solr query to run against SOLR. At this point, only where, where_not, 
    # fulltext, order and pagination are supported.  More will be added.
    #
    # It's also worth noting that where and where_not make use of individual filter_queries.
    # If that's not what you want, you might be better off constructing your own fulltext
    # query and sending that in.
    def query_via_solr
      filter_queries = []
      orders = []
      @where_values.each do |wv|
        wv.each do |k,v|
          v = solr_format(v)
          # If v is blank, check that there is no value for the field in the document
          filter_queries << (v.blank? ? "-#{k}:#{full_solr_range(k)}" : "#{k}:(#{v})")
        end
      end
      
      @where_not_values.each do |wnv|
        wnv.each do |k,v|
          v = solr_format(v)
          # If v is blank, check for any value for the field in document
          filter_queries << (v.blank? ? "#{k}:#{full_solr_range(k)}" : "-#{k}:(#{v})")
        end
      end
      
      @greater_than_values.each do |gtv|
        gtv.each do |k,v|
          v = solr_format(v)
          filter_queries << "#{k}:[#{v} TO *]"
        end
      end
      
      @less_than_values.each do |ltv|
        ltv.each do |k,v|
          v = solr_format(v)
          filter_queries << "#{k}:[* TO #{v}]"
        end
      end
      
      @order_values.each do |ov|
        ov.each do |k,v|
          if(@reverse_order_value)
            orders << "#{k} #{v == :asc ? 'desc' : 'asc'}"
          else
            orders << "#{k} #{v == :asc ? 'asc' : 'desc'}"
          end
        end
      end
      
      sort = orders.join(",")
      
      if @fulltext_values.empty?
        q = "*:*"
      else
        q = @fulltext_values.collect {|ftv| "(" + ftv[:query] + ")"}.join(' AND ')
        hl_fields = @fulltext_values.collect { |ftv| ftv[:highlight].join(",") if ftv[:highlight].present? }.join(",")
      end
      
      params = {:q => q}
      unless sort.empty?
        params[:sort] = sort
      end
      
      unless filter_queries.empty?
        params[:fq] = filter_queries
      end

      # Facets
      # facet=true to enable faceting,  facet.field=<field_name> (can appear more than once for multiple fields)
      # Additional options: f.<field_name>.facet.<option> [e.g. f.author.facet.sort=index]
      
      # Facet Fields
      unless field_facet_values.empty?
        params['facet'] = 'true'
        facet_fields = []
        field_facet_values.each do |facet|
          facet_field = facet[:field]
          facet_fields << facet_field
          facet[:options].each do |key,value|
            params["f.#{facet_field}.facet.#{key}"] = value.to_s
          end
        end
        params['facet.field'] = facet_fields
      end

      # Facet Ranges
      unless range_facet_values.empty?
        params['facet'] = 'true'
        facet_fields = []
        range_facet_values.each do |facet|
          facet_field = facet[:field]
          facet_fields << facet_field
          facet[:options].each do |key,value|
            params["f.#{facet_field}.facet.range.#{key}"] = value.to_s
          end
        end
        params['facet.range'] = facet_fields
      end
      
      if @highlight_options[:fields].present?
        params[:hl] = true
        params['hl.fl'] = @highlight_options[:fields]
        params['hl.snippets'] = @highlight_options[:snippets] if @highlight_options[:snippets]
        params['hl.fragsize'] = @highlight_options[:fragsize] if @highlight_options[:fragsize]
        if @highlight_options[:use_fast_vector]
          params['hl.useFastVectorHighlighter'] = true
          params['hl.tag.pre'] = @highlight_options[:pre_tag] if @highlight_options[:pre_tag].present?
          params['hl.tag.post'] = @highlight_options[:post_tag] if @highlight_options[:post_tag].present?
        else
          params['hl.mergeContiguous'] = !!@highlight_options[:merge_contiguous]
          params['hl.simple.pre'] = @highlight_options[:pre_tag] if @highlight_options[:pre_tag].present?
          params['hl.simple.post'] = @highlight_options[:post_tag] if @highlight_options[:post_tag].present?
        end
      end
      
      select_columns = select_values.empty? ? (@klass.attribute_definitions.keys - @klass.lazy_attributes) : select_values.flatten
      select_columns << "id"
      params[:fl] = select_columns.collect(&:to_s).join(",")
      unless(@stats_values.empty?)
        params[:stats] = 'true'
        @stats_values.flatten.each do |sv|
          params['stats.field'] = sv
        end
        if(@group_value)
          params['stats.facet'] = @group_value
        end
      end
      solr_response = nil
      if(@group_value)
        results = DatastaxRails::GroupedCollection.new
        params[:group] = 'true'
        params[:rows] = 10000
        params['group.field'] = @group_value
        params['group.limit'] = @per_page_value
        params['group.offset'] = (@page_value - 1) * @per_page_value
        params['group.ngroups'] = 'false' # must be false due to issues with solr sharding
        solr_response = rsolr.post('select', :data => params)
        response = solr_response["grouped"][@group_value.to_s]
        results.total_groups = response['groups'].size
        results.total_for_all = response['matches'].to_i
        results.total_entries = 0
        response['groups'].each do |group|
          results[group['groupValue']] = parse_docs(group['doclist'], select_columns)
          results.total_entries = results[group['groupValue']].total_entries if results[group['groupValue']].total_entries > results.total_entries
        end
      else
        solr_response = rsolr.paginate(@page_value, @per_page_value, 'select', :data => params, :method => :post)
        response = solr_response["response"]
        pp solr_response if ENV['DEBUG_SOLR'] == 'true'
        results = parse_docs(response, select_columns)
        results.highlights = solr_response['highlighting']
      end
      if solr_response["stats"]
        @stats = solr_response["stats"]["stats_fields"].with_indifferent_access
      end
      # Apply Facets if they exist
      if solr_response['facet_counts']
        results.facets = {}
        results.facets = results.facets.merge(solr_response['facet_counts']['facet_fields'].to_h)
        results.facets = results.facets.merge(solr_response['facet_counts']['facet_ranges'].to_h)
      end
      pp params if ENV['DEBUG_SOLR'] == 'true'
      results
    end
    
    # Parse out a set of documents and return the results
    #
    # @param response [Hash] the response hash from SOLR with a set of documents
    # @param select_columns [Array] the columns that we actually selected from SOLR
    #
    # @return [DatastaxRails::Collection] the resulting collection
    def parse_docs(response, select_columns)
      results = DatastaxRails::Collection.new
      results.per_page = @per_page_value
      results.current_page = @page_value || 1
      results.total_entries = response['numFound'].to_i
      response['docs'].each do |doc|
        id = doc['id']
        if(@consistency_value)
          obj = @klass.with_cassandra.consistency(@consistency_value).find_by_id(id)
          results << obj if obj
        else
          #byebug
          results << @klass.instantiate(id, doc, select_columns)
        end
      end
      results
    end
    protected(:parse_docs)
    
    # Formats a value for solr (assuming this is a solr query).
    def solr_format(value)
      return value unless use_solr_value
      case
        when value.is_a?(Time)
          value.utc.strftime(DatastaxRails::Types::TimeType::FORMAT)
        when value.is_a?(DateTime)
          value.to_time.utc.strftime(DatastaxRails::Types::TimeType::FORMAT)
        when value.is_a?(Date)
          value.strftime(DatastaxRails::Types::TimeType::FORMAT)
        when value.is_a?(Array)
          value.collect {|v| v.to_s.gsub(/ /,"\\ ") }.join(" OR ")
        when value.is_a?(Fixnum)
          value < 0 ? "\\#{value}" : value
        when value.is_a?(Range)
          "[#{solr_format(value.first)} TO #{solr_format(value.last)}]"
        when value.is_a?(String)
          solr_escape(downcase_query(value.gsub(/ /,"\\ ")))
        when value.is_a?(FalseClass), value.is_a?(TrueClass)
          value.to_s
        else
          value
      end
    end
    
    # Inspects the results of the search instead of the Relation itself.
    # Passing true causes the Relation to be inspected.
    #
    # @param [Boolean] just_me if true, inspect the Relation, otherwise the results
    def inspect(just_me = false)
      just_me ? super() : to_a.inspect
    end
    
    # Scope all queries to the current scope.
    #
    # ==== Example
    #
    #   Comment.where(:post_id => 1).scoping do
    #     Comment.first # SELECT * FROM comments WHERE post_id = 1
    #   end
    #
    # Please check unscoped if you want to remove all previous scopes (including
    # the default_scope) during the execution of a block.
    def scoping
      @klass.send(:with_scope, self, :overwrite) { yield }
    end
    
    # Merges all of the where values together into a single hash
    def where_values_hash
      where_values.inject({}) { |values,v| values.merge(v) }
    end

    # Creates a scope that includes all of the where values plus anything
    # that is in +create_with_value+.
    def scope_for_create
      @scope_for_create ||= where_values_hash.merge(create_with_value)
    end
    
    # Sends a commit message to SOLR
    def commit_solr
      rsolr.commit :commit_attributes => {}
    end
    
    # Everything that gets indexed into solr is downcased as part of the analysis phase.
    # Normally, this is done to the query as well, but if your query includes wildcards
    # then analysis isn't performed.  This means that the query does not get downcased.
    # We therefore need to perform the downcasing ourselves.  This does it while still
    # leaving boolean operations (AND, OR, NOT) upcased.
    def downcase_query(value)
      if(value.is_a?(String))
        value.split(/\bAND\b/).collect do |a|
          a.split(/\bOR\b/).collect do |o| 
            o.split(/\bNOT\b/).collect do |n| 
              n.downcase
            end.join("NOT")
          end.join("OR")
        end.join("AND")
      else
        value
      end
    end
    
    protected
      
      def method_missing(method, *args, &block) #:nodoc:
        if DatastaxRails::Collection.method_defined?(method)
          to_a.send(method, *args, &block)
        elsif @klass.respond_to?(method, true)
          scoping { @klass.send(method, *args, &block) }
        else
          super
        end
      end
      
      # Calculates the solr URL and sets up an RSolr connection
      def rsolr
        @klass.solr_connection
      end
  end
end