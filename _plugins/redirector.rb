module SamplePlugin
  class RedirectPageGenerator < Jekyll::Generator
    safe true

    def generate(site)
      config = site.data['redirects']
      config.each { |redirectConfig|
        Jekyll.logger.info "generating redoirects for #{redirectConfig[0]}"
        redirectConfig[1]['mappings'].each do |mapping|
          Jekyll.logger.info "generating redoirect for #{redirectConfig[0]}/#{mapping['name']}"
          site.pages << RedirectPage.new(site, redirectConfig[0], redirectConfig[1], mapping)
        end
        Jekyll.logger.info "loaded redirect pages #{redirectConfig[0]}"
      }
    Jekyll.logger.info "finished generating redirects"
    end
  end

  # Subclass of `Jekyll::Page` with custom method definitions.
  class RedirectPage < Jekyll::Page
    def initialize(site, group, redirectConfig, mapping)

        @site = site             # the current site instance.
        @base = site.source      # path to the source directory.
        @dir  = "/redirect/#{group}/"         # the directory the page will reside in.

          # All pages have the same filename, so define attributes straight away.
        @basename = mapping['name']      # filename without the extension.
        @ext      = '.html'      # the extension.
        @name     = basename + ext # basically @basename + @ext.
        @layout  = 'redirect.html'

        @content = "#{redirectConfig['baseUrl']}#{mapping['path']}"

        # Initialize data hash with a key pointing to all posts under current category.
        # This allows accessing the list in a template via `page.linked_docs`.
        @data = {
          'version' => mapping['fromVersion'],
          'target' => redirectConfig['baseUrl'] + mapping['path'],
        }

        # # Look up front matter defaults scoped to type `categories`, if given key
        # # doesn't exist in the `data` hash.
        data.default_proc = proc do |_, key|
          site.frontmatter_defaults.find(relative_path, type, key)
        end
        Jekyll.logger.info "generated redirect page #{@dir}#{@basename}"
    end

    # Placeholders that are used in constructing page URL.
    def url_placeholders
      {
        :path       => @dir,
        :category   => @dir,
        :basename   => basename,
        :output_ext => output_ext,
      }
    end
  end
end