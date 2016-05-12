#include "macros.h"

#ifndef CEOS_OPCODES_H
#define CEOS_OPCODES_H

#define OPCODE_ADDRESS(__op) (uintptr_t)op_##__op,

#define EXTERN_OPCODE(opcode) \
  extern "C" void op_##opcode ();

#define OPCODES \
      ret, \
      bind, \
      push, \
      call, \
      jz, \
      jmp, \
      create_closure, \
      load_string, \
      push_arg, \
      lookup, \
      exit, \
      create_lex_scope, \
      release_lex_scope, \
      put_to_scope

EVAL(MAP(EXTERN_OPCODE, OPCODES))

namespace ceos {

class Opcode {
  public:

  ENUM(Type, OPCODES);

  static uintptr_t opcodeAddress(Opcode::Type t) {
    return (uintptr_t []) {
      EVAL(MAP(OPCODE_ADDRESS, OPCODES))
    }[(int)t];
  }
};

}

#define READ_INT(FROM, TO) \
    int64_t TO; \
    FROM.read(reinterpret_cast<char *>(&TO), sizeof(TO)); \
    if (FROM.eof() || FROM.fail()) return

#define READ_STR(FROM, TO) \
    std::stringstream TO##_; \
    FROM.get(*TO##_.rdbuf(), '\0'); \
    std::string TO = TO##_.str(); \
    FROM.ignore(1);

#endif
