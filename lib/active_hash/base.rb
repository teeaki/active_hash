module ActiveHash

  class RecordNotFound < StandardError
  end

  class ReservedFieldError < StandardError
  end

  class IdError < StandardError
  end

  class FileTypeMismatchError < StandardError
  end

  class FieldTypeError < StandardError
  end

  def self.type_methods
    @type_methods ||= {string: :to_s, integer: :to_i, float: :to_f}.tap do |type_methods|
      type_methods[:bool] = :to_bool if ''.respond_to? :to_bool
      type_methods[:datetime] = :to_datetime if ''.respond_to? :to_datetime
      type_methods[:date] = :to_date if ''.respond_to? :to_date
      type_methods[:time] = :to_time if ''.respond_to? :to_time
    end
  end

  class Base
    if respond_to?(:class_attribute)
      class_attribute :_data, :dirty
    else
      class_inheritable_accessor :_data, :dirty
    end

    if Object.const_defined?(:ActiveModel)
      extend ActiveModel::Naming
      include ActiveModel::Conversion
    else
      def to_param
        id.present? ? id.to_s : nil
      end
    end

    class << self

      def cache_key
        if Object.const_defined?(:ActiveModel)
          model_name.cache_key
        else
          ActiveSupport::Inflector.tableize(self)
        end
      end

      def primary_key
        "id"
      end

      def field_names
        field_options.keys
      end

      def attribute_names
        [:id] + field_names
      end

      def field_options
        @field_options ||= {}
      end

      def the_meta_class
        class << self
          self
        end
      end

      def compute_type(type_name)
        if type_name.match(/^::/)
          # If the type is prefixed with a scope operator then we assume that
          # the type_name is an absolute reference.
          ActiveSupport::Dependencies.constantize(type_name)
        else
          # Build a list of candidates to search for
          candidates = []
          name.scan(/::|$/) { candidates.unshift "#{$`}::#{type_name}" }
          candidates << type_name

          candidates.each do |candidate|
            begin
              constant = ActiveSupport::Dependencies.constantize(candidate)
              return constant if candidate == constant.to_s
            rescue NameError => e
              # We don't want to swallow NoMethodError < NameError errors
              raise e unless e.instance_of?(NameError)
            end
          end

          raise NameError, "uninitialized constant #{candidates.first}"
        end
      end

      def pluralize_table_names
        true
      end

      def data
        _data
      end

      def data=(array_of_hashes)
        mark_dirty
        @records = nil
        reset_record_index
        self._data = array_of_hashes
        if array_of_hashes
          auto_assign_fields(array_of_hashes)
          array_of_hashes.each do |hash|
            insert new(hash)
          end
        end
      end

      def exists?(record)
        if record.id.present?
          record_index[record.id.to_s].present?
        end
      end

      def insert(record)
        @records ||= []
        record.attributes[:id] ||= next_id
        validate_unique_id(record) if dirty
        mark_dirty

        add_to_record_index({ record.id.to_s => @records.length })
        @records << record
      end

      def next_id
        max_record = all.max { |a, b| a.id <=> b.id }
        if max_record.nil?
          1
        elsif max_record.id.is_a?(Numeric)
          max_record.id.succ
        end
      end

      def record_index
        @record_index ||= {}
      end

      private :record_index

      def reset_record_index
        record_index.clear
      end

      private :reset_record_index

      def add_to_record_index(entry)
        record_index.merge!(entry)
      end

      private :add_to_record_index

      def validate_unique_id(record)
        raise IdError.new("Duplicate ID found for record #{record.attributes.inspect}") if record_index.has_key?(record.id.to_s)
      end

      private :validate_unique_id

      def create(attributes = {})
        record = new(attributes)
        record.save
        mark_dirty
        record
      end

      alias_method :add, :create

      def create!(attributes = {})
        record = new(attributes)
        record.save!
        record
      end

      def transaction
        yield
      rescue LocalJumpError => err
        raise err
      rescue StandardError => e
        unless Object.const_defined?(:ActiveRecord) && e.is_a?(ActiveRecord::Rollback)
          raise e
        end
      end

      def delete_all
        mark_dirty
        reset_record_index
        @records = []
      end

      def all(options = {})
        ScopedArray.new(@records || [], self).all(options)
      end

      def find_by_id(id)
        index = record_index[id.to_s]
        index and @records[index]
      end

      delegate :first, :last, :where, :count, :find, :find_by, :to => :all

      def fields(*args)
        options = args.extract_options!
        args.each do |field|
          field(field, options)
        end
      end

      def field(field_name, options = {})
        validate_field(field_name)
        type = options[:type]
        validate_type(type) if type
        field_options[field_name] = options

        type_method = ActiveHash.type_methods[type]
        define_getter_method(field_name, options[:default])
        define_setter_method(field_name, type_method)
        define_interrogator_method(field_name)
        define_custom_find_method(field_name, type_method)
        define_custom_find_all_method(field_name, type_method)
      end

      def validate_field(field_name)
        if [:attributes].include?(field_name.to_sym)
          raise ReservedFieldError.new("#{field_name} is a reserved field in ActiveHash.  Please use another name.")
        end
      end

      def validate_type(type)
        raise FieldTypeError.new("#{type} not in #{ActiveHash.type_methods.keys.inspect}") unless ActiveHash.type_methods[type]
      end

      private :validate_field, :validate_type

      def respond_to?(method_name, include_private=false)
        super ||
          begin
            config = configuration_for_custom_finder(method_name)
            config && config[:fields].all? do |field|
              field_names.include?(field.to_sym) || field.to_sym == :id
            end
          end
      end

      def method_missing(method_name, *args)
        return super unless respond_to? method_name

        config = configuration_for_custom_finder(method_name)
        attribute_pairs = config[:fields].zip(args)
        matches = all.select { |base| attribute_pairs.all? { |field, value| base.send(field).to_s == value.to_s } }

        if config[:all?]
          matches
        else
          result = matches.first
          if config[:bang?]
            result || raise(RecordNotFound, "Couldn\'t find #{name} with #{attribute_pairs.collect { |pair| "#{pair[0]} = #{pair[1]}" }.join(', ')}")
          else
            result
          end
        end
      end

      def configuration_for_custom_finder(finder_name)
        if finder_name.to_s.match(/^find_(all_)?by_(.*?)(!)?$/) && !($1 && $3)
          {
            :all? => !!$1,
            :bang? => !!$3,
            :fields => $2.split('_and_')
          }
        end
      end

      private :configuration_for_custom_finder

      def define_getter_method(field, default_value)
        unless has_instance_method?(field)
          define_method(field) do
            attributes[field].nil? ? default_value : attributes[field]
          end
        end
      end

      private :define_getter_method

      def define_setter_method(field, type_method)
        method_name = "#{field}="
        unless has_instance_method?(method_name)
          define_method(method_name) do |new_val|
            attributes[field] = new_val.nil? ? nil : type_method.nil? ? new_val : new_val.send(type_method)
          end
        end
      end

      private :define_setter_method

      def define_interrogator_method(field)
        method_name = :"#{field}?"
        unless has_instance_method?(method_name)
          define_method(method_name) do
            send(field).present?
          end
        end
      end

      private :define_interrogator_method

      def define_custom_find_method(field_name, type_method)
        method_name = :"find_by_#{field_name}"
        unless has_singleton_method?(method_name)
          the_meta_class.instance_eval do
            define_method(method_name) do |*args|
              options = args.extract_options!
              identifier = args[0].nil? ? nil : type_method.nil? ? args[0] : args[0].send(type_method)
              all.detect { |record| record.send(field_name) == identifier }
            end
          end
        end
      end

      private :define_custom_find_method

      def define_custom_find_all_method(field_name, type_method)
        method_name = :"find_all_by_#{field_name}"
        unless has_singleton_method?(method_name)
          the_meta_class.instance_eval do
            unless singleton_methods.include?(method_name)
              define_method(method_name) do |*args|
                options = args.extract_options!
                identifier = args[0].nil? ? nil : type_method.nil? ? args[0] : args[0].send(type_method)
                all.select { |record| record.send(field_name) == identifier }
              end
            end
          end
        end
      end

      private :define_custom_find_all_method

      def auto_assign_fields(array_of_hashes)
        (array_of_hashes || []).inject([]) do |array, row|
          row.symbolize_keys!
          row.keys.each do |key|
            unless key.to_s == "id"
              array << key
            end
          end
          array
        end.uniq.each do |key|
          field key
        end
      end

      private :auto_assign_fields

      # Needed for ActiveRecord polymorphic associations
      def base_class
        ActiveHash::Base
      end

      def reload
        reset_record_index
        self.data = _data
        mark_clean
      end

      private :reload

      def mark_dirty
        self.dirty = true
      end

      private :mark_dirty

      def mark_clean
        self.dirty = false
      end

      private :mark_clean

      def has_instance_method?(name)
        instance_methods.map { |method| method.to_sym }.include?(name.to_sym)
      end

      private :has_instance_method?

      def has_singleton_method?(name)
        singleton_methods.map { |method| method.to_sym }.include?(name)
      end

      private :has_singleton_method?

    end

    attr_reader :attributes

    def initialize(attributes = {})
      attributes.symbolize_keys!
      @attributes = attributes
      attributes.dup.each do |key, value|
        send "#{key}=", value
      end
      (self.class.field_options.keys - attributes.keys).each do |key|
        options = self.class.field_options[key]
        send "#{key}=", options[:default] if options.has_key?(:default)
      end
    end

    def [](key)
      respond_to?(key) ? send(key) : nil
    end

    def []=(key, val)
      attributes[key] = val
    end

    def id
      attributes[:id] ? attributes[:id] : nil
    end

    def id=(id)
      attributes[:id] = id
    end

    alias quoted_id id

    def new_record?
      !self.class.all.include?(self)
    end

    def destroyed?
      false
    end

    def persisted?
      self.class.all.map(&:id).include?(id)
    end

    def readonly?
      true
    end

    def eql?(other)
      other.instance_of?(self.class) and not id.nil? and (id == other.id)
    end

    alias == eql?

    def hash
      id.hash
    end

    def cache_key
      case
        when new_record?
          "#{self.class.cache_key}/new"
        when timestamp = self[:updated_at]
          "#{self.class.cache_key}/#{id}-#{timestamp.to_s(:number)}"
        else
          "#{self.class.cache_key}/#{id}"
      end
    end

    def errors
      obj = Object.new

      def obj.[](key)
        []
      end

      def obj.full_messages()
        []
      end

      obj
    end

    def save(*args)
      unless self.class.exists?(self)
        self.class.insert(self)
      end
      true
    end

    alias save! save

    def valid?
      true
    end

    def marked_for_destruction?
      false
    end

    def read_attribute(name)
      attributes[name.to_sym]
    end

    def write_attribute(name, value)
      attributes[name.to_sym] = value
    end

    def update_attributes(attrs)
      attrs.each{|key, val| self[key.to_sym] = val }
    end
  end
end
