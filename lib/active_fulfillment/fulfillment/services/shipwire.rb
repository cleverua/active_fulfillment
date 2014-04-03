require 'cgi'

module ActiveMerchant
  module Fulfillment
    class ShipwireService < Service

      SERVICE_URLS = { :fulfillment  => 'https://api.shipwire.com/exec/FulfillmentServices.php',
                       :inventory    => 'https://api.shipwire.com/exec/InventoryServices.php',
                       :tracking     => 'https://api.shipwire.com/exec/TrackingServices.php',
                       :rate         => 'https://api.shipwire.com/exec/RateServices.php'
                     }

      SCHEMA_URLS = { :fulfillment => 'http://www.shipwire.com/exec/download/OrderList.dtd',
                      :inventory   => 'http://www.shipwire.com/exec/download/InventoryUpdate.dtd',
                      :tracking    => 'http://www.shipwire.com/exec/download/TrackingUpdate.dtd',
                      :rate        => 'http://www.shipwire.com/exec/download/RateRequest.dtd'
                    }

      POST_VARS = { :fulfillment => 'OrderListXML',
                    :inventory   => 'InventoryUpdateXML',
                    :tracking    => 'TrackingUpdateXML',
                    :rate        => 'RateRequestXML'
                  }

      WAREHOUSES = { 'CHI' => 'Chicago',
                     'LAX' => 'Los Angeles',
                     'REN' => 'Reno',
                     'VAN' => 'Vancouver',
                     'TOR' => 'Toronto',
                     'UK'  => 'United Kingdom'
                   }

      INVALID_LOGIN = /(Error with Valid Username\/EmailAddress and Password Required)|(Could not verify Username\/EmailAddress and Password combination)/

      class_attribute :affiliate_id

      # The first is the label, and the last is the code
      def self.shipping_methods
        [ ['1 Day Service',   '1D'],
          ['2 Day Service',   '2D'],
          ['Ground Service',  'GD'],
          ['Freight Service', 'FT'],
          ['International', 'INTL']
        ].inject(ActiveSupport::OrderedHash.new){|h, (k,v)| h[k] = v; h}
      end

      # Pass in the login and password for the shipwire account.
      # Optionally pass in the :test => true to force test mode
      def initialize(options = {})
        requires!(options, :login, :password)

        super
      end

      def fulfill(order_id, shipping_address, line_items, options = {})
        commit :fulfillment, build_fulfillment_request(order_id, shipping_address, line_items, options)
      end

      def fetch_stock_levels(options = {})
        commit :inventory, build_inventory_request(options)
      end

      def fetch_tracking_data(order_ids, options = {})
        commit :tracking, build_tracking_request(order_ids)
      end

      def fetch_rate_data(order_id, shipping_address, line_items, options = {})
        commit :rate, build_rate_request(order_id, shipping_address, line_items, options)
      end

      def valid_credentials?
        response = fetch_tracking_numbers([])
        response.message !~ INVALID_LOGIN
      end

      def test_mode?
        true
      end

      def include_pending_stock?
        @options[:include_pending_stock]
      end

      def include_empty_stock?
        @options[:include_empty_stock]
      end

      private
      def build_fulfillment_request(order_id, shipping_address, line_items, options)
        xml = Builder::XmlMarkup.new :indent => 2
        xml.instruct!
        xml.declare! :DOCTYPE, :OrderList, :SYSTEM, SCHEMA_URLS[:fulfillment]
        xml.tag! 'OrderList' do
          add_credentials(xml)
          xml.tag! 'Referer', 'Active Fulfillment'
          add_order(xml, order_id, shipping_address, line_items, options)
        end
        xml.target!
      end

      def build_inventory_request(options)
        xml = Builder::XmlMarkup.new :indent => 2
        xml.instruct!
        xml.declare! :DOCTYPE, :InventoryStatus, :SYSTEM, SCHEMA_URLS[:inventory]
        xml.tag! 'InventoryUpdate' do
          add_credentials(xml)
          xml.tag! 'Warehouse', WAREHOUSES[options[:warehouse]]
          xml.tag! 'ProductCode', options[:sku]
          xml.tag! 'IncludeEmpty' if include_empty_stock?
        end
      end

      def build_tracking_request(order_ids)
        xml = Builder::XmlMarkup.new
        xml.instruct!
        xml.declare! :DOCTYPE, :InventoryStatus, :SYSTEM, SCHEMA_URLS[:inventory]
        xml.tag! 'TrackingUpdate' do
          add_credentials(xml)
          xml.tag! 'Server', test? ? 'Test' : 'Production'
          order_ids.each do |o_id|
            xml.tag! 'OrderNo', o_id
          end
        end
      end

      def build_rate_request(order_id, shipping_address, line_items, options)
        options[:rate] = true
        xml = Builder::XmlMarkup.new :indent => 2
        xml.instruct!
        xml.declare! :DOCTYPE, :RateRequest, :SYSTEM, SCHEMA_URLS[:rate]
        xml.tag! 'RateRequest' do
          add_rate_credentials(xml)
          add_order(xml, order_id, shipping_address, line_items, options)
        end
      end

      def add_credentials(xml)
        xml.tag! 'EmailAddress', @options[:login]
        xml.tag! 'Password', @options[:password]
        xml.tag! 'Server', test? ? 'Test' : 'Production'
        xml.tag! 'AffiliateId', affiliate_id if affiliate_id.present?
      end

      def add_rate_credentials(xml)
        xml.tag! 'EmailAddress', @options[:login]
        xml.tag! 'Password', @options[:password]
        xml.tag! 'Server', 'Production'
      end

      def add_order(xml, order_id, shipping_address, line_items, options)
        xml.tag! 'Order', :id => order_id do
          xml.tag! 'Warehouse', options[:warehouse] || '00'

          add_address(xml, shipping_address, options)
          xml.tag! 'Shipping', options[:shipping_method] unless (options[:shipping_method].blank? &&  options[:rate])

          Array(line_items).each_with_index do |line_item, index|
            add_item(xml, line_item, index)
          end
          xml.tag! 'Note' do
            xml.cdata! options[:note] unless options[:note].blank?
          end
        end
      end

      def add_address(xml, address, options)
        xml.tag! 'AddressInfo', :type => 'Ship' do
          unless options[:rate]
            xml.tag! 'Name' do
              xml.tag! 'Full', address[:name]
            end
          end

          xml.tag! 'Address1', address[:address1]
          xml.tag! 'Address2', address[:address2]

          xml.tag! 'Company', address[:company] unless options[:rate]

          xml.tag! 'City', address[:city]
          xml.tag! 'State', address[:state] unless address[:state].blank?
          xml.tag! 'Country', address[:country]

          xml.tag! 'Zip', address[:zip]
          xml.tag! 'Phone', address[:phone] unless (address[:phone].blank? && options[:rate])
          xml.tag! 'Email', options[:email] unless (options[:email].blank? && options[:rate])
        end
      end

      # Code is limited to 12 characters
      def add_item(xml, item, index)
        xml.tag! 'Item', :num => index do
          xml.tag! 'Code', item[:sku]
          xml.tag! 'Quantity', item[:quantity]
        end
      end

      def commit(action, request)
        data = ssl_post(SERVICE_URLS[action], "#{POST_VARS[action]}=#{CGI.escape(request)}")

        response = parse_response(action, data)
        Response.new(response[:success], response[:message], response, :test => test?)
      end

      def parse_response(action, data)
        case action
        when :fulfillment
          parse_fulfillment_response(data)
        when :inventory
          parse_inventory_response(data)
        when :tracking
          parse_tracking_response(data)
        when :rate
          parse_rate_response(data)
        else
          raise ArgumentError, "Unknown action #{action}"
        end
      end

      def parse_fulfillment_response(xml)
        response = {}

        document = REXML::Document.new(xml)
        document.root.elements.each do |node|
          response[node.name.underscore.to_sym] = text_content(node)
        end

        response[:success] = response[:status] == '0'
        response[:message] = response[:success] ? "Successfully submitted the order" : message_from(response[:error_message])
        response
      end

      def parse_inventory_response(xml)
        response = {}
        response[:stock_levels] = {}

        document = REXML::Document.new(xml)
        document.root.elements.each do |node|
          if node.name == 'Product'
            to_check = ['quantity']
            to_check << 'pending' if include_pending_stock?

            amount = to_check.sum { |a| node.attributes[a].to_i }
            response[:stock_levels][node.attributes['code']] = amount
          else
            response[node.name.underscore.to_sym] = text_content(node)
          end
        end

        response[:success] = test? ? response[:status] == 'Test' : response[:status] == '0'
        response[:message] = response[:success] ? "Successfully received the stock levels" : message_from(response[:error_message])

        response
      end

      def parse_tracking_response(xml)
        response = {}
        response[:tracking_numbers] = {}
        response[:tracking_companies] = {}
        response[:tracking_urls] = {}

        document = REXML::Document.new(xml)
        document.root.elements.each do |node|
          if node.name == 'Order'
            if node.attributes["shipped"] == "YES" && node.elements['TrackingNumber']
              tracking_number = node.elements['TrackingNumber'].text.strip
              response[:tracking_numbers][node.attributes['id']] = [tracking_number]

              tracking_company = node.elements['TrackingNumber'].attributes['carrier']
              response[:tracking_companies][node.attributes['id']] = tracking_company.strip if tracking_company

              tracking_url = node.elements['TrackingNumber'].attributes['href']
              response[:tracking_urls][node.attributes['id']] = [tracking_url.strip] if tracking_url
            end
          else
            response[node.name.underscore.to_sym] = text_content(node)
          end
        end

        response[:success] = test? ? (response[:status] == '0' || response[:status] == 'Test') : response[:status] == '0'
        response[:message] = response[:success] ? "Successfully received the tracking numbers" : message_from(response[:error_message])
        response
      end

      def parse_rate_response(xml)
        response = {}
        response[:quote] = {}
        response[:warnings] = []

        document = REXML::Document.new(xml)
        document.root.elements.each do |node|
          if node.name == 'Order'
            node.each do |order|
              if !order.try(:name).nil? && order.name == 'Quotes'
                order.each do |quote|
                  if !quote.try(:name).nil? && quote.name == 'Quote'
                    quote_method = quote.attributes['method']
                    response[:quote][quote_method] = {}

                    quote_warehouse = quote.elements['Warehouse'].text.strip
                    response[:quote][quote_method]['warehouse'] = quote_warehouse

                    quote_service = quote.elements['Service'].text.strip
                    response[:quote][quote_method]['service'] = quote_service

                    total_cost= quote.elements['Cost'].attributes['originalCost']
                    cost_currency = quote.elements['Cost'].attributes['currency']
                    response[:quote][quote_method]['cost'] = {}
                    response[:quote][quote_method]['cost']['total'] = total_cost
                    response[:quote][quote_method]['cost']['currency'] = cost_currency

                    response[:quote][quote_method]['subtotal'] = {}
                    quote.elements['Subtotals'].each do |subtotal|
                      if !subtotal.try(:name).nil? && subtotal.name == 'Subtotal'
                        sub_type = subtotal.attributes['type'].downcase!
                        original_cost = subtotal.elements['Cost'].attributes['originalCost']
                        response[:quote][quote_method]['subtotal'][sub_type] = original_cost
                      end
                    end
                    response[:quote][quote_method]['estimate'] = {}
                    estimate_min_day = quote.elements['DeliveryEstimate'].elements['Minimum'].text.strip
                    response[:quote][quote_method]['estimate']['min_day'] = estimate_min_day

                    estimate_max_day = quote.elements['DeliveryEstimate'].elements['Maximum'].text.strip
                    response[:quote][quote_method]['estimate']['max_day'] = estimate_max_day
                  end
                end
              end
              if !order.try(:name).nil? && order.name == 'Warnings'
                order.each do |warning|
                  if !warning.try(:name).nil? && warning.name == 'Warning'
                    response[:warnings] << warning.text.strip
                  end
                end
              end
            end
          else
            response[node.name.underscore.to_sym] = text_content(node)
          end
        end

        response[:success] = response[:status] == 'OK'
        response[:message] = response[:success] ? "Successfully received the rate data" : message_from(response[:error_message])
        response
      end

      def message_from(string)
        return if string.blank?
        string.gsub("\n", '').squeeze(" ")
      end

      def text_content(xml_node)
        text = xml_node.text
        text = xml_node.cdatas.join if text.blank?
        text
      end
    end
  end
end


