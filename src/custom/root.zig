//! Hand-written codecs for protocol shapes the schema vocabulary cannot
//! express. Each is introduced by a reviewed `custom_types` decision.
pub const RecipeIngredient = @import("recipe_ingredient.zig").RecipeIngredient;

test {
    _ = @import("recipe_ingredient.zig");
}
