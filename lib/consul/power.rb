module Consul
  module Power
    include Consul::Power::DynamicAccess::InstanceMethods

    def self.included(base)
      base.extend ClassMethods
      base.send :include, Memoizer
    end

    private

    def default_include_power?(power_name, *context)
      result = send(power_name, *context)
      # Everything that is not nil is considered as included.
      # We are short-circuiting for #scoped first since sometimes
      # has_many associations (which behave scopish) trigger their query
      # when you try to negate them, compare them or even retrieve their
      # class. Unfortunately we can only reproduce this in live Rails
      # apps, not in Consul tests. Might be some standard gem that is not
      # loaded in Consul tests.
      result = !result.empty? if result.respond_to?(:empty?, true)
      result.respond_to?(:load_target, true) || !!result
    end

    def default_include_object?(power_name, *args)
      object = args.pop
      context = args
      power_value = send(power_name, *context)
      if power_value.nil?
        false
      elsif Util.scope?(power_value)
        if Util.scope_selects_all_records?(power_value)
          true
        else
          power_ids_name = self.class.power_ids_name(power_name)
          send(power_ids_name, *context).include?(object.id)
        end
      elsif Util.collection?(power_value)
        power_value.include?(object)
      else
        raise Consul::NoCollection, "can only call #include_object? on a collection, but power was of type #{power_value.class.name}"
      end
    end

    def default_power_ids(power_name, *args)
      scope = send(power_name, *args)
      database_touched
      scope.collect_ids
    end

    def powerless!(*args)
      raise Consul::Powerless.new("No power to #{[*args].inspect}")
    end

    def boolean_or_nil?(value)
      [TrueClass, FalseClass, NilClass].include?(value.class)
    end

    def database_touched
      # spy for tests
    end

    def singularize_power_name(name)
      self.class.singularize_power_name(name)
    end



    module ClassMethods
      include Consul::Power::DynamicAccess::ClassMethods

      def power(*names, &block)
        names.each do |name|
          define_power(name, &block)
        end
      end

      def power_ids_name(name)
        "#{name.to_s.singularize}_ids"
      end

      def self.thread_key(klass)
        "consul|#{klass.to_s}.current"
      end

      def current
        Thread.current[ClassMethods.thread_key(self)]
      end

      def current=(power)
        Thread.current[ClassMethods.thread_key(self)] = power
      end

      def with_power(inner_power, &block)
        unless inner_power.is_a?(self) || inner_power.nil?
          inner_power = new(inner_power)
        end
        old_power = current
        self.current = inner_power
        block.call
      ensure
        self.current = old_power
      end

      def without_power(&block)
        with_power(nil, &block)
      end

      def define_query_and_bang_methods(name, &query)
        query_method = "#{name}?"
        bang_method = "#{name}!"
        define_method(query_method, &query)
        define_method(bang_method) { |*args| send(query_method, *args) or powerless!(name, *args) }
      end

      def define_power(name, &block)
        name = name.to_s
        if name.ends_with?('?')
          name_without_suffix = name.chop
          define_query_and_bang_methods(name_without_suffix, &block)
        else
          define_method(name, &block)
          define_query_and_bang_methods(name) { |*args| default_include_power?(name, *args) }
          begin
            singular = singularize_power_name(name)
            define_query_and_bang_methods(singular) { |*args| default_include_object?(name, *args) }
          rescue Consul::PowerNotSingularizable
            # We do not define singularized power methods if it would
            # override the collection method
          end
          ids_method = power_ids_name(name)
          define_method(ids_method) { |*args| default_power_ids(name, *args) }
          memoize ids_method
        end
        name
      end

      def singularize_power_name(name)
        name = name.to_s
        singularized = name.singularize
        if singularized == name
          raise Consul::PowerNotSingularizable, "Power name can not have an singular form: #{name}"
        else
          singularized
        end
      end

    end
  end
end
