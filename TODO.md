- Hash and equality on AbstractProtoBufMessage can be dropped. @batteries will define them for any subtype
  /home/jan/.julia/dev/ProtocGen/src/ProtocGen.jl:63
  /home/jan/.julia/dev/ProtocGen/src/ProtocGen.jl:71

- Lets only have

```julia
function StructHelpers.default_values(::Type{<:AbstractProtoBufMessage})
    (; var"#unknown_fields" = UInt8[])
end
```

The user can overload default_values if needed for subtypes.

- Add more type annotations to function signatures. Especially return type is missing a lot

- could we use Base64.jl instead of rolling our own?
- force running julia formatter in CI

- Are there alternatives to the global register_message_type mechanism?
  For instance we might want to generate multiple julia packages that happen
  have some colliding FQN from completly distinct proto specs.
