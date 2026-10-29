// Input: physical 3DS controls represented by the 3duos shell.
// Output: emulator-independent button and stick identities.
// Pos: shared input contract between console UI and emulator sessions.

enum ConsoleButtonID {
    case up, down, left, right
    case a, b, x, y
    case leftTrigger, rightTrigger, zl, zr
    case select, start
}

enum ConsoleStickID {
    case circlePad, cStick
}
