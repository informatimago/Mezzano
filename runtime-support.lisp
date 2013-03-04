(in-package #:sys.int)

(defun proclaim (declaration-specifier)
  (case (first declaration-specifier)
    (special (dolist (var (rest declaration-specifier))
               (setf (system:symbol-mode var) :special)))
    (constant (dolist (var (rest declaration-specifier))
                (setf (system:symbol-mode var) :constant)))
    (inline
     (dolist (name (rest declaration-specifier))
       (let ((sym (function-symbol name)))
         (setf (get sym 'inline-mode) t))))
    (notinline
     (dolist (name (rest declaration-specifier))
       (let ((sym (function-symbol name)))
         (setf (get sym 'inline-mode) nil))))))

(defun system:symbol-mode (symbol)
  (svref #(nil :special :constant :symbol-macro)
         (ldb (byte 2 0) (%symbol-flags symbol))))

(defun (setf system:symbol-mode) (value symbol)
  (setf (ldb (byte 2 0) (%symbol-flags symbol))
        (ecase value
          ((nil) +symbol-mode-nil+)
          ((:special) +symbol-mode-special+)
          ((:constant) +symbol-mode-constant+)
          ((:symbol-macro) +symbol-mode-symbol-macro+)))
  value)

(defun variable-information (symbol)
  (symbol-mode symbol))

;;; The compiler can only handle (apply function arg-list).
(defun apply (function arg &rest more-args)
  (declare (dynamic-extent more-args))
  (cond (more-args
         ;; Convert (... (final-list ...)) to (... final-list...)
         (do* ((arg-list (cons arg more-args))
               (i arg-list (cdr i)))
              ((null (cddr i))
               (setf (cdr i) (cadr i))
               (apply function arg-list))))
        (t (apply function arg))))

;;; TODO: This requires a considerably more flexible mechanism.
;;; 12 is where the TLS slots in a stack group start.
;;; NOTE: Is set by initialize-lisp during cold boot.
(defvar *next-symbol-tls-slot* 12)
(defconstant +maximum-tls-slot+ 512)
(defun %allocate-tls-slot (symbol)
  (when (>= *next-symbol-tls-slot* +maximum-tls-slot+)
    (error "Critial error! TLS slots exhausted!"))
  (let ((slot *next-symbol-tls-slot*))
    (incf *next-symbol-tls-slot*)
    (setf (ldb (byte 16 8) (%symbol-flags symbol)) slot)
    slot))

(defun %symbol-tls-slot (symbol)
  (ldb (byte 16 8) (%symbol-flags symbol)))

(defun symbol-tls-slot (symbol)
  (let ((slot (ldb (byte 16 8) (%symbol-flags symbol))))
    (if (zerop slot) nil slot)))

(defun funcall (function &rest arguments)
  (declare (dynamic-extent arguments))
  (apply function arguments))

(defun values (&rest values)
  (declare (dynamic-extent values))
  (values-list values))

(defun constantly (value)
  (lambda (&rest arguments)
    (declare (ignore arguments))
    value))

(defun fboundp (name)
  (%fboundp (function-symbol name)))

(defun fmakunbound (name)
  (%fmakunbound (function-symbol name))
  name)

(defun macro-function (symbol &optional env)
  (dolist (e env
           (get symbol '%macro-function))
    (when (eql (first e) :macros)
      (let ((fn (assoc symbol (rest e))))
        (when fn (return (cdr fn)))))))

(defun (setf macro-function) (value symbol &optional env)
  (when env
    (error "TODO: (Setf Macro-function) in environment."))
  (setf (symbol-function symbol) (lambda (&rest r)
                                   (declare (ignore r))
                                   (error 'undefined-function :name symbol))
        (get symbol '%macro-function) value))

;;; Calls to these functions are generated by the compiler to
;;; signal errors.
(defun raise-undefined-function (invoked-through &rest args)
  ;; Convert setf-symbols back to (setf foo).
  (when (and (symbolp invoked-through)
             (get invoked-through 'setf-symbol-backlink))
    (setf invoked-through `(setf ,(get invoked-through 'setf-symbol-backlink))))
  ;; Allow restarting.
  (restart-case (error 'undefined-function :name invoked-through)
    (use-value (v)
      :interactive (lambda ()
                     (format t "Enter a new value (evaluated): ")
                     (list (eval (read))))
      :report (lambda (s) (format s "Input a value to be used in place of ~S." `(fdefinition ',invoked-through)))
      (apply v args))))

(defun raise-undefined-function-via-%symbol-function (invoked-through)
  ;; Convert setf-symbols back to (setf foo).
  (when (and (symbolp invoked-through)
             (get invoked-through 'setf-symbol-backlink))
    (setf invoked-through `(setf ,(get invoked-through 'setf-symbol-backlink))))
  (error 'undefined-function :name invoked-through))

(defun raise-unbound-error (symbol)
  (error 'unbound-variable :name symbol))

(defun raise-type-error (datum expected-type)
  (error 'type-error :datum datum :expected-type expected-type))

(defun %invalid-argument-error (&rest args)
  (error "Invalid arguments to function."))

(defun endp (list)
  (cond ((null list) t)
        ((consp list) nil)
        (t (error 'type-error
                  :datum list
                  :expected-type 'list))))

(defun list (&rest args)
  args)

(defun copy-list (list &optional area)
  (when list
    (cons-in-area (car list) (copy-list (cdr list)) area)))

;;; Will be overriden later in the init process.
(defun funcallable-instance-lambda-expression (function)
  (values nil t nil))

(defun function-name (function)
  (check-type function function)
  (let* ((address (logand (lisp-object-address function) -16))
         (info (memref-unsigned-byte-64 address 0)))
    (ecase (logand info #xFF)
      (#.+function-type-function+ ;; Regular function. First entry in the constant pool.
       (memref-t address (* (logand (ash info -16) #xFFFF) 2)))
      (#.+function-type-closure+ ;; Closure.
       (function-name (memref-t address 4)))
      (#.+function-type-funcallable-instance+
       (multiple-value-bind (lambda closurep name)
           (funcallable-instance-lambda-expression function)
         (declare (ignore lambda closurep))
         name)))))

(defun function-lambda-expression (function)
  (check-type function function)
  (let* ((address (logand (lisp-object-address function) -16))
         (info (memref-unsigned-byte-64 address 0)))
    (ecase (logand info #xFF)
      (#.+function-type-function+ ;; Regular function. First entry in the constant pool.
       (values nil nil (memref-t address (* (logand (ash info -16) #xFFFF) 2))))
      (#.+function-type-closure+ ;; Closure.
       (values nil t (function-name (memref-t address 4))))
      (#.+function-type-funcallable-instance+
       (funcallable-instance-lambda-expression function)))))

(defun funcallable-std-instance-p (object)
  (when (functionp object)
    (let* ((address (logand (lisp-object-address object) -16))
           (info (memref-unsigned-byte-64 address 0)))
      (eql (ldb (byte 8 0) info) +function-type-funcallable-instance+))))

(defun funcallable-std-instance-function (funcallable-instance)
  (assert (funcallable-std-instance-p funcallable-instance) (funcallable-instance))
  (let* ((address (logand (lisp-object-address funcallable-instance) -16)))
    (memref-t address 4)))
(defun (setf funcallable-std-instance-function) (value funcallable-instance)
  (check-type value function)
  (assert (funcallable-std-instance-p funcallable-instance) (funcallable-instance))
  (let* ((address (logand (lisp-object-address funcallable-instance) -16)))
    (setf (memref-t address 4) value)))

(defun funcallable-std-instance-class (funcallable-instance)
  (assert (funcallable-std-instance-p funcallable-instance) (funcallable-instance))
  (let* ((address (logand (lisp-object-address funcallable-instance) -16)))
    (memref-t address 5)))
(defun (setf funcallable-std-instance-class) (value funcallable-instance)
  (assert (funcallable-std-instance-p funcallable-instance) (funcallable-instance))
  (let* ((address (logand (lisp-object-address funcallable-instance) -16)))
    (setf (memref-t address 5) value)))

(defun funcallable-std-instance-slots (funcallable-instance)
  (assert (funcallable-std-instance-p funcallable-instance) (funcallable-instance))
  (let* ((address (logand (lisp-object-address funcallable-instance) -16)))
    (memref-t address 6)))
(defun (setf funcallable-std-instance-slots) (value funcallable-instance)
  (assert (funcallable-std-instance-p funcallable-instance) (funcallable-instance))
  (let* ((address (logand (lisp-object-address funcallable-instance) -16)))
    (setf (memref-t address 6) value)))

(defun compiled-function-p (object)
  (when (functionp object)
    (let* ((address (logand (lisp-object-address object) -16))
           (info (memref-unsigned-byte-64 address 0)))
      (not (eql (logand info #xFF) +function-type-interpreted-function+)))))

(defvar *gensym-counter* 0)
(defun gensym (&optional (thing "G"))
  (make-symbol (format nil "~A~D" thing (prog1 *gensym-counter* (incf *gensym-counter*)))))

;;; TODO: Expand this so it knows about the compiler's constant folders.
(defun constantp (form &optional environment)
  (declare (ignore environment))
  (typecase form
    (symbol (eql (symbol-mode form) :constant))
    (cons (eql (first form) 'quote))
    (t t)))

(defvar *active-catch-handlers* '())
(defun %catch (tag fn)
  (let ((*active-catch-handlers* (cons (cons tag
                                             (lambda (values)
                                               (return-from %catch (values-list values))))
                                       *active-catch-handlers*)))
    (funcall fn)))

(defun %throw (tag values)
  (let ((target (assoc tag *active-catch-handlers* :test 'eq)))
    (if target
        (funcall (cdr target) values)
        (error 'bad-catch-tag-error
               :tag tag))))

;;; Bind one symbol. (symbol value)
(define-lap-function %%bind ()
  ;; Ensure there is a TLS slot.
  (sys.lap-x86:mov32 :eax (:symbol-flags :r8))
  (sys.lap-x86:shr32 :eax #.sys.c::+tls-offset-shift+)
  (sys.lap-x86:and32 :eax #xFFFF)
  (sys.lap-x86:jnz has-tls-slot)
  ;; Nope, allocate a new one.
  (sys.lap-x86:mov64 (:lsp -8) nil)
  (sys.lap-x86:mov64 (:lsp -16) nil)
  (sys.lap-x86:sub64 :lsp 16)
  (sys.lap-x86:mov64 (:lsp 0) :r8)
  (sys.lap-x86:mov64 (:lsp 8) :r9)
  (sys.lap-x86:mov64 :r13 (:constant sys.int::%allocate-tls-slot))
  (sys.lap-x86:mov32 :ecx 8)
  (sys.lap-x86:call (:symbol-function :r13))
  (sys.lap-x86:mov64 :lsp :rbx)
  (sys.lap-x86:mov64 :rax :r8)
  (sys.lap-x86:shr32 :eax 3)
  (sys.lap-x86:mov64 :r8 (:lsp 0))
  (sys.lap-x86:mov64 :r9 (:lsp 8))
  (sys.lap-x86:add64 :lsp 16)
  has-tls-slot
  ;; Save the old value on the binding stack.
  ;; See also: http://www.sbcl.org/sbcl-internals/Binding-and-unbinding.html
  ;; Bump binding stack.
  (sys.lap-x86:gs)
  (sys.lap-x86:sub64 (#.sys.c::+binding-stack-gs-offset+) 16)
  ;; Load binding stack pointer into R11.
  (sys.lap-x86:gs)
  (sys.lap-x86:mov64 :r11 (#.sys.c::+binding-stack-gs-offset+))
  ;; Read the old symbol value.
  (sys.lap-x86:gs)
  (sys.lap-x86:mov64 :r10 ((:rax 8) #.sys.c::+tls-base-offset+))
  ;; Store the old value on the stack.
  (sys.lap-x86:mov64 (:r11 8) :r10)
  ;; Store the symbol.
  (sys.lap-x86:mov64 (:r11) :r8)
  ;; Store new value.
  (sys.lap-x86:gs)
  (sys.lap-x86:mov64 ((:rax 8) #.sys.c::+tls-base-offset+) :r9)
  (sys.lap-x86:xor32 :ecx :ecx)
  (sys.lap-x86:mov64 :rbx :lsp)
  (sys.lap-x86:ret))

(defun %progv (symbols values)
  (do ((s symbols (rest s))
       (v values (rest v)))
      ((null s))
    (check-type (first s) symbol)
    (%%bind (first s) (if v
                          (first v)
                          (%%assemble-value 0 +tag-unbound-value+)))))

(defun function-tag (function)
  (check-type function function)
  (let* ((address (logand (lisp-object-address function) -16))
         (info (memref-unsigned-byte-64 address 0)))
    (ldb (byte 8 0) info)))

(defun function-pool-size (function)
  (check-type function function)
  (let* ((address (logand (lisp-object-address function) -16))
         (info (memref-unsigned-byte-64 address 0)))
    (ldb (byte 16 32) info)))

(defun function-code-size (function)
  (check-type function function)
  (let* ((address (logand (lisp-object-address function) -16))
         (info (memref-unsigned-byte-64 address 0)))
    (* (ldb (byte 16 16) info) 16)))

(defun function-pool-object (function offset)
  (check-type function function)
  (let* ((address (logand (lisp-object-address function) -16))
         (info (memref-unsigned-byte-64 address 0))
         (mc-size (* (ldb (byte 16 16) info) 2))) ; in words.
    (memref-t address (+ mc-size offset))))

(defun function-code-byte (function offset)
  (check-type function function)
  (let* ((address (logand (lisp-object-address function) -16))
         (info (memref-unsigned-byte-64 address 0)))
    (memref-unsigned-byte-8 address offset)))

(defun get-structure-type (name &optional (errorp t))
  (or (get name 'structure-type)
      (and errorp
           (error "Unknown structure type ~S." name))))

(defun concat-symbols (&rest symbols)
  (intern (apply 'concatenate 'string (mapcar 'string symbols))))

(defvar *gentemp-counter* 0)

(defun gentemp (&optional (prefix "T") (package *package*))
  (do () (nil)
    (let ((name (format nil "~A~D" prefix (incf *gentemp-counter*))))
      (multiple-value-bind (x status)
          (find-symbol name package)
        (declare (ignore x))
        (unless status (return (intern name package)))))))
