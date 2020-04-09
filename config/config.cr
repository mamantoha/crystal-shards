require "dotenv"

Dotenv.load?

require "./initializers/**"
require "../src/models/*"
require "../src/delegators"
require "../src/helpers/*"
require "../src/jobs/*"
