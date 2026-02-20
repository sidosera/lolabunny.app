#ifndef BUNNYLOL_H
#define BUNNYLOL_H

#include <stdint.h>

// Starts the bunnylol server on the given port.
// Blocks until the server shuts down. Returns 0 on success, 1 on error.
int32_t bunnylol_serve(uint16_t port);

#endif
