- Lets only have

```julia
function StructHelpers.default_values(::Type{<:AbstractProtoBufMessage})
    (; var"#unknown_fields" = UInt8[])
end
```

The user can overload default_values if needed for subtypes.

- Add more type annotations to function signatures. Especially return type is missing a lot

- Are there alternatives to the global register_message_type mechanism?
  For instance we might want to generate multiple julia packages that happen
  have some colliding FQN from completly distinct proto specs.
