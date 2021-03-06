module ActsAsTenant
  @@models_with_global_records = []

  def self.models_with_global_records
    @@models_with_global_records
  end

  def self.add_global_record_model model
    @@models_with_global_records.push(model)
  end

  def self.current_tenant=(tenant)
    RequestStore.store[:current_tenant] = tenant
  end

  def self.current_tenant
    RequestStore.store[:current_tenant] || self.default_tenant
  end

  def self.unscoped=(unscoped)
    RequestStore.store[:acts_as_tenant_unscoped] = unscoped
  end

  def self.unscoped
    RequestStore.store[:acts_as_tenant_unscoped]
  end

  def self.unscoped?
    !!unscoped
  end

  def self.current_tenant_klass
    raise ActsAsTenant::Errors::NoTenantSet unless current_tenant

    current_tenant.class.name.demodulize.downcase.to_sym
  end

  class << self
    def default_tenant=(tenant)
      @default_tenant = tenant
    end

    def default_tenant
      if unscoped
        nil
      else
        @default_tenant
      end
    end
  end


  def self.with_tenant(tenant, &block)
    if block.nil?
      raise ArgumentError, "block required"
    end

    old_tenant = self.current_tenant
    self.current_tenant = tenant
    value = block.call
    return value
  ensure
    self.current_tenant = old_tenant
  end

  def self.without_tenant(&block)
    if block.nil?
      raise ArgumentError, "block required"
    end

    old_tenant = current_tenant
    old_unscoped = unscoped

    self.current_tenant = nil
    self.unscoped = true
    value = block.call
    return value
  ensure
    self.current_tenant = old_tenant
    self.unscoped = old_unscoped
  end

  module ModelExtensions
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def acts_as_tenant(tenant = :account, options = {})
        ActsAsTenant.add_global_record_model(self) if options[:has_global_records]

        # Create the association
        valid_options = options.slice(:foreign_key, :class_name, :inverse_of, :optional, :foreign_type)
        fkey = valid_options[:foreign_key] || "#{tenant}_id".to_sym
        polymorphic_type = valid_options[:foreign_type] || "#{tenant}_type"
        belongs_to tenant, valid_options

        default_scope lambda {
          if ActsAsTenant.configuration.require_tenant && ActsAsTenant.current_tenant.nil? && !ActsAsTenant.unscoped?
            raise ActsAsTenant::Errors::NoTenantSet
          end
          if ActsAsTenant.current_tenant && (ActsAsTenant.current_tenant_klass == tenant || options[:polymorphic])
            keys = [ActsAsTenant.current_tenant.id]
            keys.push(nil) if options[:has_global_records]

            query_criteria = { fkey.to_sym => keys }
            query_criteria.merge!({ polymorphic_type.to_sym => ActsAsTenant.current_tenant.class.to_s }) if options[:polymorphic]
            where(query_criteria)
          else
            Rails::VERSION::MAJOR < 4 ? scoped : all
          end
        }

        # Add the following validations to the receiving model:
        # - new instances should have the tenant set
        # - validate that associations belong to the tenant, currently only for belongs_to
        #
        before_validation Proc.new {|m|
          if ActsAsTenant.current_tenant
            if options[:polymorphic]
              m.send("#{fkey}=".to_sym, ActsAsTenant.current_tenant.id)
              m.send("#{polymorphic_type}=".to_sym, ActsAsTenant.current_tenant.class.to_s)
            elsif ActsAsTenant.current_tenant_klass == tenant
              m.send "#{fkey}=".to_sym, ActsAsTenant.current_tenant.id
            end
          end
        }, :on => :create

        polymorphic_foreign_keys = reflect_on_all_associations(:belongs_to).select do |a|
          a.options[:polymorphic]
        end.map { |a| a.foreign_key }

        reflect_on_all_associations(:belongs_to).each do |a|
          unless a == reflect_on_association(tenant) || polymorphic_foreign_keys.include?(a.foreign_key)
            association_class =  a.options[:class_name].nil? ? a.name.to_s.classify.constantize : a.options[:class_name].constantize
            validates_each a.foreign_key.to_sym do |record, attr, value|
              primary_key = if association_class.respond_to?(:primary_key)
                              association_class.primary_key
                            else
                              a.primary_key
                            end.to_sym
              record.errors.add attr, "association is invalid [ActsAsTenant]" unless value.nil? || association_class.where(primary_key => value).any?
            end
          end
        end

        # Dynamically generate the following methods:
        # - Rewrite the accessors to make tenant immutable
        # - Add an override to prevent unnecessary db hits
        # - Add a helper method to verify if a model has been scoped by AaT
        to_include = Module.new do
          define_method "#{fkey}=" do |integer|
            write_attribute("#{fkey}", integer)
            raise ActsAsTenant::Errors::TenantIsImmutable if send("#{fkey}_changed?") && persisted? && !send("#{fkey}_was").nil?
            integer
          end

          define_method "#{tenant.to_s}=" do |model|
            super(model)
            raise ActsAsTenant::Errors::TenantIsImmutable if send("#{fkey}_changed?") && persisted? && !send("#{fkey}_was").nil?
            model
          end

          define_method "#{tenant.to_s}" do
            if !ActsAsTenant.current_tenant.nil? && send(fkey) == ActsAsTenant.current_tenant.id && ActsAsTenant.current_tenant_klass == tenant
              return ActsAsTenant.current_tenant
            else
              super()
            end
          end
        end
        include to_include

        class << self
          def scoped_by_tenant?
            true
          end
        end
      end

      def validates_uniqueness_to_tenant(fields, args = {})
        raise ActsAsTenant::Errors::ModelNotScopedByTenant unless respond_to?(:scoped_by_tenant?)
        tenant = args[:tenant] || :account
        fkey = reflect_on_association(tenant).foreign_key
        if args[:scope]
          args[:scope] = Array(args[:scope]) << fkey
        else
          args[:scope] = fkey
        end

        validates_uniqueness_of(fields, args)

        if ActsAsTenant.models_with_global_records.include?(self)
          validate do |instance|
            Array(fields).each do |field|
              if instance.new_record?
                unless self.class.where(fkey.to_sym => [nil, instance[fkey]],
                                        field.to_sym => instance[field]).empty?
                  errors.add(field, 'has already been taken')
                end
              else
                unless self.class.where(fkey.to_sym => [nil, instance[fkey]],
                                        field.to_sym => instance[field])
                                 .where.not(:id => instance.id).empty?
                  errors.add(field, 'has already been taken')
                end
              end
            end
          end
        end
      end
    end
  end
end
