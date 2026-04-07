import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class MyStackTest {
    @Test
    void testStackOperations() {
        MyStack<String> stack = new MyStack<>();
        stack.push("Hello");
        stack.push("World");
        
        assertEquals(2, stack.getSize());
        assertEquals("World", stack.top());
        
        stack.pop();
        assertEquals("Hello", stack.top());
        assertFalse(stack.isEmpty());
    }
}
