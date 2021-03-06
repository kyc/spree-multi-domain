require "spree_multi_domain"

module SpreeMultiDomain

  class Engine < Rails::Engine

    def self.activate

      Spree::BaseController.class_eval do
        helper_method :current_store
        helper :products, :taxons

        private

        # Tell Rails to look in layouts/#{@store.code} whenever we're inside of a store (instead of the standard /layouts location)
        def find_layout(layout, format, html_fallback=false) #:nodoc:
          layout_dir = current_store ? "layouts/#{current_store.code.downcase}" : "layouts"
          view_paths.find_template(layout.to_s =~ /\A\/|layouts\// ? layout : "#{layout_dir}/#{layout}", format, html_fallback)
        rescue ActionView::MissingTemplate
          raise if Mime::Type.lookup_by_extension(format.to_s).html?
        end

        def current_store
          @current_store ||= ::Store.by_domain(request.env['SERVER_NAME']).first
          @current_store ||= ::Store.default.first
        end

        def get_taxonomies
          @taxonomies ||= Taxonomy.find(:all, :include => {:root => :children}, :conditions => ["store_id = ?", @site.id])
          @taxonomies
        end

      end

      Product.class_eval do
        has_and_belongs_to_many :stores
        scope :by_store, lambda {|store| joins(:stores).where("products_stores.store_id = ?", store)}
      end

      ProductsController.class_eval do
        before_filter :can_show_product, :only => :show

        private
        def can_show_product
         if @product.stores.empty? || @product.stores.include?(@site)
           render :file => "public/404.html", :status => 404
         end
        end

      end

      #override search to make it multi-store aware
      Spree::Search.module_eval do
        def retrieve_products
          # taxon might be already set if this method is called from TaxonsController#show
          @taxon ||= Taxon.find_by_id(params[:taxon]) unless params[:taxon].blank?
          # add taxon id to params for searcher
          params[:taxon] = @taxon.id if @taxon
          @keywords = params[:keywords]
          
          per_page = params[:per_page].to_i
          per_page = per_page > 0 ? per_page : Spree::Config[:products_per_page]
          params[:per_page] = per_page
          params[:page] = 1 if (params[:page].to_i <= 0)
          
          # Prepare a search within the parameters
          Spree::Config.searcher.prepare(params)

          if !params[:order_by_price].blank?
            @product_group = ProductGroup.new.from_route([params[:order_by_price]+"_by_master_price"])
          elsif params[:product_group_name]
            @cached_product_group = ProductGroup.find_by_permalink(params[:product_group_name])
            @product_group = ProductGroup.new
          elsif params[:product_group_query]
            @product_group = ProductGroup.new.from_route(params[:product_group_query])
          else
            @product_group = ProductGroup.new
          end

          @product_group = @product_group.from_search(params[:search]) if params[:search]
       
          base_scope = @cached_product_group ? @cached_product_group.products.active : Product.active
          base_scope = base_scope.by_store(current_store.id) if current_store.present?

          base_scope = base_scope.in_taxon(@taxon) unless @taxon.blank? 
          base_scope = base_scope.keywords(@keywords) unless @keywords.blank?
          
          base_scope = base_scope.on_hand unless Spree::Config[:show_zero_stock_products]
          @products_scope = @product_group.apply_on(base_scope)

          curr_page = Spree::Config.searcher.manage_pagination ? 1 : params[:page]
          @products = @products_scope.all.paginate({
              :include  => [:images, :master],
              :per_page => per_page,
              :page     => curr_page
            })
          @products_count = @products_scope.count

          return(@products)
        end
      end

      Admin::ProductsController.class_eval do
        update.before << :set_stores

        create.before << :add_to_all_stores

        private
        def set_stores
          @product.store_ids = nil unless params[:product].key? :store_ids
        end

        def add_to_all_stores
        end
      end

      Order.class_eval do
        belongs_to :store
        scope :by_store, lambda { |store| where(:store_id => store.id) }
      end

      Taxonomy.class_eval do
        belongs_to :store
      end

      Tracker.class_eval do
        belongs_to :store

        def self.current
          trackers = Tracker.find(:all, :conditions => {:active => true, :environment => ENV['RAILS_ENV']})
          trackers.select { |t| t.store.name == Spree::Config[:site_name] }.first
        end
      end
    end

    config.autoload_paths += %W(#{config.root}/lib)
    config.to_prepare &method(:activate).to_proc

  end

end


Spree::CurrentOrder.module_eval do
  def current_order_with_multi_domain(create_order_if_necessary = false)
    current_order_without_multi_domain(create_order_if_necessary)
    if @current_order and current_store and @current_order.store.nil?
      @current_order.update_attribute(:store_id, current_store.id)
    end
    @current_order
  end
  alias_method_chain :current_order, :multi_domain
end

