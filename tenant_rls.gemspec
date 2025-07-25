
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'tenant_rls/version'

Gem::Specification.new do |spec|
  spec.name          = 'tenant_rls'
  spec.version       = TenantRls::VERSION
  spec.authors       = ['Punith Kumar']
  spec.email         = ['s_punith@vebuin.com']

  spec.summary       = 'Flexible Rails Row-Level Security helper for multi-tenant applications'
  spec.description   = 'A flexible Rails gem for implementing PostgreSQL Row-Level Security (RLS) in multi-tenant applications. Supports multiple authentication patterns including Devise/Warden, custom authentication, and background job processing.'
  spec.homepage      = 'https://smartflow.vebuin.com'
  spec.license       = 'MIT'

  if spec.respond_to?(:metadata)
    spec.metadata['allowed_push_host'] = 'https://smartflow.vebuin.com/'
  else
    raise 'RubyGems 2.0 or newer is required to protect against public gem pushes.'
  end

  spec.files = Dir.chdir(File.expand_path('..', __FILE__)) do
    `git ls-files -z`.split("\x0").reject {|f| f.match(%r{^(test|spec|features)/}) }
  end
  spec.bindir        = 'exe'
  spec.executables   = spec.files.grep(%r{^exe/}) {|f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_development_dependency 'bundler', '>= 1.17'
  spec.add_development_dependency 'rake', '>= 10.0'
  spec.add_development_dependency 'rspec', '~> 3.0'
  spec.add_dependency 'rails', '>= 4.0'
  spec.add_dependency 'concurrent-ruby', '~> 1.2'
  spec.add_dependency 'activesupport', '>= 4.0'
end
