# models.jl — Model info and pricing loaded from models.dev api.json
module Models

using JSON3

const API_JSON_PATH = joinpath(@__DIR__, "gui", "public", "api.json")

# (input_price, output_price) in USD per 1M tokens
const PRICING = Dict{String, Tuple{Float64, Float64}}()

function load_pricing!()
  empty!(PRICING)
  isfile(API_JSON_PATH) || return
  data = JSON3.read(read(API_JSON_PATH, String))
  for (provider_key, provider_data) in pairs(data)
    models = get(provider_data, :models, nothing)
    models === nothing && continue
    for (model_key, model_data) in pairs(models)
      cost = get(model_data, :cost, nothing)
      cost === nothing && continue
      input_price = get(cost, :input, nothing)
      output_price = get(cost, :output, nothing)
      (input_price === nothing || output_price === nothing) && continue
      id = string(get(model_data, :id, model_key))
      PRICING[id] = (Float64(input_price), Float64(output_price))
    end
  end
end

load_pricing!()

function compute_cost(model::String, input_tokens::Int, output_tokens::Int)::Float64
  prices = get(PRICING, model, nothing)
  prices === nothing && return 0.0
  (input_price, output_price) = prices
  (input_tokens * input_price + output_tokens * output_price) / 1_000_000
end

end # module
