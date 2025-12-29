# iOS App Layer System

Rules for the ContentView UI layers. Reference this document when working on layout/animation.

## Layer Definitions

| Layer | Name | Content |
|-------|------|---------|
| L0 | Background | Background color + Settings icon. STATIC, never moves. |
| L1 | Translation Card | L1T (input area) + L1B (output area) + buttons (paste, copy, share, clear) |
| L2 | Language Switcher | Source language button, swap button, target language button |
| L3 | Keyboard | System keyboard (not controlled by us) |

## Layer Behavior Rules

### L0 (Background)
- **Never moves**. Settings icon stays fixed at top-left.
- L1 covers it when keyboard appears.

### L1 (Translation Card)
- **Keyboard hidden**: Top edge below settings area (settings visible above).
- **Keyboard visible**: Top edge moves to top of screen (hides settings).
- **Bottom edge**: Always meets L2's top edge.
- **Height shrinks** when keyboard appears (top moves up, bottom moves up with L2).
- **L1T.height == L1B.height** always (50/50 split of available content space).

### L2 (Language Switcher)
- **Sticky to keyboard**. Lives just above L3.
- **Keyboard hidden**: Sits at bottom of screen.
- **Keyboard visible**: Moves up by keyboard height (minus bleed).
- Uses `bottomPadding` = `keyboardHeight - bottomBleed` for positioning.

### L3 (Keyboard)
- System controlled. We respond to `keyboardWillShowNotification` / `keyboardWillHideNotification`.

## Animation Rules

1. **All content within a layer moves together** at the same speed.
2. L1 and L2 use the same spring animation: `.spring(response: 0.3, dampingFraction: 0.9)`.
3. Animation is tied to `keyboardHeight` value changes.

## Key Constants

```swift
settingsAreaHeight: CGFloat = 16   // Space above L1 when keyboard hidden
l2Height: CGFloat = 100            // Height of L2 language switcher
bottomBleed: CGFloat = 50          // Extra extension below keyboard to cover rounded corners
```

## Visual Hierarchy (Z-order, bottom to top)

1. L0 Background
2. L0 Settings button
3. L1 Translation card
4. L2 Language switcher
5. L3 Keyboard (system)

## Important Implementation Details

- L1 and L2 both use `.ignoresSafeArea(edges: .bottom)` to extend to screen edge.
- L1's top spacer: `isKeyboardVisible ? 0 : safeTop + settingsAreaHeight`
- Both L1 and L2 use `.padding(.bottom, bottomPadding)` to position above keyboard.
- L2's Spacer has `.allowsHitTesting(false)` so touches pass through to L1.
